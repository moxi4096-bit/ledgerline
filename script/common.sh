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

# deploy <rpc> <contract path:name> <value> [constructor args...] -> prints the deployed address
deploy() {
    local rpc="$1" contract="$2" value="$3"
    shift 3
    local args=()
    [ $# -gt 0 ] && args=(--constructor-args "$@")
    forge create --root "$ROOT" --rpc-url "$rpc" --private-key "$PRIVATE_KEY" --broadcast --json \
        --value "$value" "$contract" "${args[@]}" \
        | python3 -c "import json,sys; r=json.load(sys.stdin); print(r['deployedTo'])"
}

# send <rpc> <to> <sig> [args...] -> prints the tx hash; fails if the tx reverted
send() {
    local rpc="$1" to="$2"
    shift 2
    cast send --rpc-url "$rpc" --private-key "$PRIVATE_KEY" --json "$to" "$@" \
        | python3 -c "import json,sys; r=json.load(sys.stdin); assert r['status']=='0x1', 'reverted: '+r['transactionHash']; print(r['transactionHash'])"
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
