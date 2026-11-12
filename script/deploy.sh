#!/usr/bin/env bash
# Deploy Ledgerline to Lasna + Base Sepolia + Unichain Sepolia and wire it up.
#
# Order matters: callback contracts store the reactive contract's address immutably, so the reactive
# contract goes first, then the vaults/statement, then the reactive contract learns their addresses.
#
# Env (see .env.example): PRIVATE_KEY or KEY_FILE, optional SECOND_WALLET, funding amounts below.
source "$(dirname "$0")/common.sh"
load_key

REACTIVE_FUNDING="${REACTIVE_FUNDING:-3ether}"   # lREACT for reactive transactions
CALLBACK_FUNDING="${CALLBACK_FUNDING:-0.005ether}" # destination ETH per callback contract
DAILY_LIMIT="${DAILY_LIMIT:-100000000}"          # 100 lUSD (6 decimals)
SAVINGS_BPS="${SAVINGS_BPS:-1000}"               # save 10% of every income
MIN_INCOME="${MIN_INCOME:-1000000}"              # ignore incomes under 1 lUSD
USD="$(cast format-bytes32-string USD)"

mkdir -p "$(dirname "$DEPLOYMENTS")"
log "Deployer $DEPLOYER"
json_set deployer "$DEPLOYER"

log "1/4 Lasna: LedgerlineReactive (funded with $REACTIVE_FUNDING)"
LEDGER=$(deploy "$LASNA_RPC" src/LedgerlineReactive.sol:LedgerlineReactive "$REACTIVE_FUNDING" "$DEPLOYER")
json_set lasna.ledgerline "$LEDGER"
log "    $LEDGER"

log "2/4 Base Sepolia: test token, SavingsVault, Statement"
BASE_TOKEN=$(deploy "$BASE_RPC" src/LedgerToken.sol:LedgerToken 0 "Ledgerline Test USD" lUSD 6)
BASE_VAULT=$(deploy "$BASE_RPC" src/SavingsVault.sol:SavingsVault "$CALLBACK_FUNDING" "$BASE_CALLBACK_PROXY" "$LEDGER")
STATEMENT=$(deploy "$BASE_RPC" src/Statement.sol:Statement "$CALLBACK_FUNDING" "$BASE_CALLBACK_PROXY" "$LEDGER")
json_set base.token "$BASE_TOKEN"
json_set base.vault "$BASE_VAULT"
json_set base.statement "$STATEMENT"
log "    token $BASE_TOKEN  vault $BASE_VAULT  statement $STATEMENT"

log "3/4 Unichain Sepolia: test token, SavingsVault"
UNI_TOKEN=$(deploy "$UNI_RPC" src/LedgerToken.sol:LedgerToken 0 "Ledgerline Test USD" lUSD 6)
UNI_VAULT=$(deploy "$UNI_RPC" src/SavingsVault.sol:SavingsVault "$CALLBACK_FUNDING" "$UNI_CALLBACK_PROXY" "$LEDGER")
json_set unichain.token "$UNI_TOKEN"
json_set unichain.vault "$UNI_VAULT"
log "    token $UNI_TOKEN  vault $UNI_VAULT"

log "4/4 Lasna: configure rules, wallets, tokens, vaults, statements"
send "$LASNA_RPC" "$LEDGER" "configureAsset(bytes32,uint256,uint16,uint256)" "$USD" "$DAILY_LIMIT" "$SAVINGS_BPS" "$MIN_INCOME" >/dev/null
send "$LASNA_RPC" "$LEDGER" "trackWallet(address)" "$DEPLOYER" >/dev/null
if [ -n "${SECOND_WALLET:-}" ]; then
    send "$LASNA_RPC" "$LEDGER" "trackWallet(address)" "$SECOND_WALLET" >/dev/null
fi
send "$LASNA_RPC" "$LEDGER" "trackToken(uint256,address,bytes32)" "$BASE_CHAIN_ID" "$BASE_TOKEN" "$USD" >/dev/null
send "$LASNA_RPC" "$LEDGER" "trackToken(uint256,address,bytes32)" "$UNI_CHAIN_ID" "$UNI_TOKEN" "$USD" >/dev/null
send "$LASNA_RPC" "$LEDGER" "setVault(uint256,address)" "$BASE_CHAIN_ID" "$BASE_VAULT" >/dev/null
send "$LASNA_RPC" "$LEDGER" "setVault(uint256,address)" "$UNI_CHAIN_ID" "$UNI_VAULT" >/dev/null
send "$LASNA_RPC" "$LEDGER" "setStatementTarget(uint256,address)" "$BASE_CHAIN_ID" "$STATEMENT" >/dev/null
CRON1000=$(cast call "$LEDGER" "CRON1000_TOPIC0()(uint256)" --rpc-url "$LASNA_RPC" | awk '{print $1}')
send "$LASNA_RPC" "$LEDGER" "setStatementSchedule(uint256,uint256)" "$CRON1000" "${STATEMENT_INTERVAL:-3600}" >/dev/null

log "Opt in to auto-save: approve both vaults to pull lUSD from the deployer wallet"
send "$BASE_RPC" "$BASE_TOKEN" "approve(address,uint256)" "$BASE_VAULT" "$(cast max-uint)" >/dev/null
send "$UNI_RPC" "$UNI_TOKEN" "approve(address,uint256)" "$UNI_VAULT" "$(cast max-uint)" >/dev/null

log "Done. Addresses written to $DEPLOYMENTS"
cat "$DEPLOYMENTS"
