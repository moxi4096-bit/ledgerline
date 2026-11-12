#!/usr/bin/env bash
# Shared helpers for the deploy and demo scripts. Source it; don't run it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=networks.env
source "$ROOT/script/networks.env"
[ -f "$ROOT/.env" ] && source "$ROOT/.env"

DEPLOYMENTS="${DEPLOYMENTS:-$ROOT/deployments/testnet.json}"

# The deployer key comes from PRIVATE_KEY, or from KEY_FILE (the JSON written by `cast wallet new --json`).
# It is never echoed.
load_key() {
    if [ -z "${PRIVATE_KEY:-}" ]; then
        : "${KEY_FILE:?set PRIVATE_KEY or KEY_FILE in .env}"
        [[ "$KEY_FILE" = /* ]] || KEY_FILE="$ROOT/$KEY_FILE"
        PRIVATE_KEY="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); d=d.get('data',d); d=d[0] if isinstance(d,list) else d; print(d['private_key'])" "$KEY_FILE")"
    fi
    export PRIVATE_KEY
    DEPLOYER="$(cast wallet address --private-key "$PRIVATE_KEY")"
    export DEPLOYER
}

log() { printf '\033[1;36m==>\033[0m %s\n' "$*" >&2; }

# deploy <rpc> <contract path:name> <value> [constructor args...] -> prints the deployed address.
# Retries a few times: public RPCs behind load balancers sometimes report a stale nonce.
deploy() {
    local rpc="$1" contract="$2" value="$3"
    shift 3
    local args=() out attempt
    [ $# -gt 0 ] && args=(--constructor-args "$@")
    for attempt in 1 2 3 4; do
        if out=$(forge create --root "$ROOT" --rpc-url "$rpc" --private-key "$PRIVATE_KEY" --broadcast --json \
            --value "$value" "$contract" "${args[@]}" 2>/dev/null); then
            python3 -c "import json,sys; print(json.loads(sys.argv[1])['deployedTo'])" "$out"
            return 0
        fi
        log "    deploy attempt $attempt failed, retrying"
        sleep $((attempt * 3))
    done
    return 1
}

# ensure <deployments key> <rpc> <contract> <value> [args...]: deploy once, reuse on re-runs.
ensure() {
    local key="$1" rpc="$2"
    shift 2
    local existing
    existing=$(json_get "$key" 2>/dev/null || true)
    if [ -n "$existing" ] && [ "$(cast codesize "$existing" --rpc-url "$rpc")" != "0" ]; then
        echo "$existing"
        return 0
    fi
    existing=$(deploy "$rpc" "$@")
    json_set "$key" "$existing"
    echo "$existing"
}

# send <rpc> <to> <sig> [args...] -> prints the tx hash; fails if the tx reverted
send() {
    local rpc="$1" to="$2" out attempt
    shift 2
    for attempt in 1 2 3 4; do
        if out=$(cast send --rpc-url "$rpc" --private-key "$PRIVATE_KEY" --json "$to" "$@" 2>/dev/null); then
            python3 -c "import json,sys; r=json.loads(sys.argv[1]); assert r['status']=='0x1', 'reverted: '+r['transactionHash']; print(r['transactionHash'])" "$out"
            return
        fi
        log "    send attempt $attempt failed ($3), retrying"
        sleep $((attempt * 3))
    done
    return 1
}

# call <rpc> <to> <sig> [args...] -> first word of the result
call() {
    local rpc="$1" to="$2"
    shift 2
    cast call --rpc-url "$rpc" "$to" "$@" | awk '{print $1; exit}'
}

# json_set <key> <value>: record a value in the deployments file
json_set() {
    python3 - "$DEPLOYMENTS" "$1" "$2" <<'PY'
import json, os, sys
path, key, value = sys.argv[1:]
data = json.load(open(path)) if os.path.exists(path) else {}
node = data
*parents, leaf = key.split(".")
for p in parents:
    node = node.setdefault(p, {})
node[leaf] = value
json.dump(data, open(path, "w"), indent=2)
PY
}

json_get() {
    python3 -c "import json,sys; d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split('.'): d=d[k]
print(d)" "$DEPLOYMENTS" "$1"
}
