#!/usr/bin/env bash
# Deploy Ledgerline to Lasna + Base Sepolia + Unichain Sepolia and wire it up. Safe to re-run: deployed
# contracts are reused and configuration steps that are already in place are skipped.
#
# Order matters: callback contracts store the reactive contract's address immutably, so the reactive
# contract goes first, then the vaults/statement, then the reactive contract learns their addresses.
#
# Env (see .env.example): PRIVATE_KEY or KEY_FILE, optional SECOND_WALLET, overrides below.
source "$(dirname "$0")/common.sh"
load_key

REACTIVE_FUNDING="${REACTIVE_FUNDING:-3ether}"     # lREACT for reactive transactions
CALLBACK_FUNDING="${CALLBACK_FUNDING:-0.005ether}" # destination ETH per callback contract
DAILY_LIMIT="${DAILY_LIMIT:-100000000}"            # 100 lUSD (6 decimals)
SAVINGS_BPS="${SAVINGS_BPS:-1000}"                 # save 10% of every income
MIN_INCOME="${MIN_INCOME:-1000000}"                # ignore incomes under 1 lUSD
STATEMENT_INTERVAL="${STATEMENT_INTERVAL:-3600}"   # at most one scheduled statement per hour
USD="$(cast format-bytes32-string USD)"

mkdir -p "$(dirname "$DEPLOYMENTS")"
log "Deployer $DEPLOYER"
json_set deployer "$DEPLOYER"

log "1/4 Lasna: LedgerlineReactive"
LEDGER=$(ensure lasna.ledgerline "$LASNA_RPC" src/LedgerlineReactive.sol:LedgerlineReactive "$REACTIVE_FUNDING" "$DEPLOYER")
log "    ledgerline $LEDGER"

log "2/4 Base Sepolia: test token, SavingsVault, Statement"
BASE_TOKEN=$(ensure base.token "$BASE_RPC" src/LedgerToken.sol:LedgerToken 0 "Ledgerline Test USD" lUSD 6)
BASE_VAULT=$(ensure base.vault "$BASE_RPC" src/SavingsVault.sol:SavingsVault "$CALLBACK_FUNDING" "$BASE_CALLBACK_PROXY" "$LEDGER")
STATEMENT=$(ensure base.statement "$BASE_RPC" src/Statement.sol:Statement "$CALLBACK_FUNDING" "$BASE_CALLBACK_PROXY" "$LEDGER")
log "    token $BASE_TOKEN  vault $BASE_VAULT  statement $STATEMENT"

log "3/4 Unichain Sepolia: test token, SavingsVault"
UNI_TOKEN=$(ensure unichain.token "$UNI_RPC" src/LedgerToken.sol:LedgerToken 0 "Ledgerline Test USD" lUSD 6)
UNI_VAULT=$(ensure unichain.vault "$UNI_RPC" src/SavingsVault.sol:SavingsVault "$CALLBACK_FUNDING" "$UNI_CALLBACK_PROXY" "$LEDGER")
log "    token $UNI_TOKEN  vault $UNI_VAULT"

log "4/4 Lasna: rules, wallets, tokens, vaults, statements"
send "$LASNA_RPC" "$LEDGER" "configureAsset(bytes32,uint256,uint16,uint256)" "$USD" "$DAILY_LIMIT" "$SAVINGS_BPS" "$MIN_INCOME" >/dev/null

for wallet in "$DEPLOYER" ${SECOND_WALLET:-}; do
    [ "$(call "$LASNA_RPC" "$LEDGER" "isWallet(address)(bool)" "$wallet")" = "true" ] ||
        send "$LASNA_RPC" "$LEDGER" "trackWallet(address)" "$wallet" >/dev/null
done

track_token() { # chainId token
    local active
    active=$(cast call --rpc-url "$LASNA_RPC" "$LEDGER" \
        "tokenInfo(uint256,address)((uint256,address,uint256,bool,uint256,uint256,uint256))" "$1" "$2" |
        tr -d '()' | awk -F', ' '{print $4}')
    [ "$active" = "true" ] || send "$LASNA_RPC" "$LEDGER" "trackToken(uint256,address,bytes32)" "$1" "$2" "$USD" >/dev/null
}
track_token "$BASE_CHAIN_ID" "$BASE_TOKEN"
track_token "$UNI_CHAIN_ID" "$UNI_TOKEN"

send "$LASNA_RPC" "$LEDGER" "setVault(uint256,address)" "$BASE_CHAIN_ID" "$BASE_VAULT" >/dev/null
send "$LASNA_RPC" "$LEDGER" "setVault(uint256,address)" "$UNI_CHAIN_ID" "$UNI_VAULT" >/dev/null
send "$LASNA_RPC" "$LEDGER" "setStatementTarget(uint256,address)" "$BASE_CHAIN_ID" "$STATEMENT" >/dev/null

CRON1000=$(call "$LASNA_RPC" "$LEDGER" "CRON1000_TOPIC0()(uint256)")
[ "$(call "$LASNA_RPC" "$LEDGER" "statementCronTopic()(uint256)")" = "$CRON1000" ] ||
    send "$LASNA_RPC" "$LEDGER" "setStatementSchedule(uint256,uint256)" "$CRON1000" "$STATEMENT_INTERVAL" >/dev/null

log "Opt in to auto-save: approve both vaults to pull lUSD from the deployer wallet"
MAX=$(cast max-uint)
[ "$(call "$BASE_RPC" "$BASE_TOKEN" "allowance(address,address)(uint256)" "$DEPLOYER" "$BASE_VAULT")" = "$MAX" ] ||
    send "$BASE_RPC" "$BASE_TOKEN" "approve(address,uint256)" "$BASE_VAULT" "$MAX" >/dev/null
[ "$(call "$UNI_RPC" "$UNI_TOKEN" "allowance(address,address)(uint256)" "$DEPLOYER" "$UNI_VAULT")" = "$MAX" ] ||
    send "$UNI_RPC" "$UNI_TOKEN" "approve(address,uint256)" "$UNI_VAULT" "$MAX" >/dev/null

log "Done. Addresses written to $DEPLOYMENTS"
cat "$DEPLOYMENTS"
