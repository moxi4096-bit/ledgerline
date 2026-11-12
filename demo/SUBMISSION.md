# DoraHacks submission — Ledgerline

Draft answers for the Reactive Omni Buildathon BUIDL form. Everything below is testnet-only.

## Project name

Ledgerline

## One-liner

A cross-chain budget and savings autopilot: one Reactive contract watches your wallets on Base and
Unichain, auto-saves 10% of every income, and locks every vault the moment your daily spending — summed
across chains — goes over the limit. No servers, no keepers.

## Track

**Set It and Forget It**

## Links

- Repository: https://github.com/moxi4096-bit/ledgerline
- Demo video (2:38, 1080p): https://github.com/moxi4096-bit/ledgerline/blob/main/demo/ledgerline-demo.mp4 — also in the repo at `demo/ledgerline-demo.mp4`
- Dashboard: run `python3 -m http.server` in the repo and open `/dashboard/` (static, reads chain state directly)

## Description

Your money is cross-chain; your budget isn't. A paycheck lands on Base, you spend on Unichain, and no
wallet can tell you what you spent today across both, let alone stop you before you overspend. Budgeting
apps that try need a server, API keys and your trust.

Ledgerline is a personal money tracker that runs itself. You set three rules once — a daily limit, an
auto-save rate and a statement schedule — and then forget about it:

1. **Auto-save.** When income arrives on any chain, 10% is swept into a SavingsVault on that same chain
   within seconds. The vault's own pull comes back to Lasna and is booked as *confirmed savings*, not
   spending.
2. **Cross-chain budget guard.** Spending on Base and Unichain is summed into one daily total (UTC day). At
   80% you get a warning event; when it crosses the limit, one reactive transaction sends callbacks that
   lock the vaults on *every* chain until midnight.
3. **Statements.** Reactive Cron events trigger a snapshot of every asset (income, spending, today's
   spend, limit, savings requested/confirmed) that is written to a Statement contract on Base Sepolia.

Moves between your own tracked wallets are recognised and count as neither income nor spending. A static
dashboard reads everything straight from the chains.

## How Reactive is used

- **Event subscriptions, scoped per wallet.** For each tracked wallet × token × chain the reactive
  contract subscribes to ERC-20 `Transfer` twice (topic1 = wallet for outflows, topic2 = wallet for
  inflows), so it only pays for transfers that involve you. Wallets and tokens are added and removed at
  runtime with matching `subscribe` / `unsubscribe` calls.
- **`react()` does the real work.** It keeps the unified ledger on Lasna: classifies each log as income,
  spending, an internal move or a confirmed sweep, de-duplicates by (chain, tx, log index), rolls the
  daily budget, and decides which callbacks to send.
- **Callbacks back to the origin chains** with `requestCallbackV_1_0`: `SavingsVault.sweep` on the chain
  where income arrived, `SavingsVault.lock` on every chain, `Statement.record` on Base. The destination
  contracts inherit `AbstractCallback` and check both the callback proxy and the reactive contract
  address; sweeps are replay-protected by reference id.
- **Cron.** Statements subscribe to a Cron topic (now Cron10000, ~2.8 h) with an optional minimum
  interval, switchable at runtime with `setStatementSchedule`.
- **Why it needs Reactive:** no contract on Base can see what you spent on Unichain. The cross-chain daily
  budget, and a lock that lands on every chain within ~3 seconds, only exist because a reactive contract
  sees all chains at once. Omni's 1 s blocks make the full loop fast enough that the lock lands before
  your next purchase.

## Deployed contracts (canonical deployment, shown in the video)

| Contract | Chain | Address |
| --- | --- | --- |
| LedgerlineReactive | Reactive Lasna | `0xfEafe4add13eB5a7c199dcDfD944b7A7F8276Fa9` |
| SavingsVault | Base Sepolia | `0x466CEdd72999181B14Afb9866AA056ea97fCD47d` |
| Statement | Base Sepolia | `0x3c81Aa54515f197662Be1A8867D460C2df1BCf3F` |
| lUSD test token | Base Sepolia | `0x4380B9171D3990178d0b0fc3eB585eAeBfe65146` |
| SavingsVault | Unichain Sepolia | `0x952527679b51cE7985FD260B9203A325857970A3` |
| lUSD test token | Unichain Sepolia | `0x76cC901CD283f501DfCa802f20f18a0534696Fb9` |

## Full-loop transaction hashes (origin → Lasna `react()` → callback)

Run 2026-11-12 16:07 (UTC+8), recorded in the video. Explorers: sepolia.basescan.org,
sepolia.uniscan.xyz, lasna.reactscan.net.

**Auto-save on Base Sepolia** — 3.85 s wall clock
- Origin (Base, 500 lUSD income): `0xcb60540cd53449c393ec65a2ceb37088512d66e890d47fd10128b50e470661ad`
- Reactive (Lasna): `0xbda91cfe1eabc50a793af6cf635ca9b7b2dddc26542781b3b6d36a88232b9637`
- Callback (Base, `SavingsVault.sweep` 50 lUSD): `0xab566add324aed4a2ff6196b6ee3cc2b1cdfd14e432feb084da81997fe0959bb`

**Auto-save on Unichain Sepolia** — 5.32 s
- Origin (Unichain, 200 lUSD income): `0x156c4d2da8ff7ae3f4df3077319a4b3a9957a136028e99ffe209beb7692da183`
- Reactive (Lasna): `0x38566f01a42885e2adaaadaa0dfafc1a2a8ae52952a76f3d868ff76320f0c54a`
- Callback (Unichain, `SavingsVault.sweep`): `0x3b91eb7d2cae2a473293547a9e9e8853e7253788ac90e65eb467e06c7cb44aec`

**Cross-chain budget lock** — one spend, two chains locked (3.05 s / 3.54 s)
- Earlier spend (Unichain, 70 lUSD): `0xb0463e0e4cb6d11ee0878e04220762c9ad5a53989a7ffa7f902728d14e3447d1`
- Origin (Base, 40 lUSD → daily total 110 / 100): `0xd6a0f32b5284c3bfef33bf1acc5ada5ebc2fa430be998e5f7339bd9af7e20d65`
- Reactive (Lasna, `SpendRecorded` + `BudgetExceeded`): `0xe5848d39b1ce07fef50d48762a3ef61d9378f1f5a4fe2ed61589b8607cc88cc9`
- Callback (Base, `SavingsVault.lock`): `0xc40856a390a76a326d9e0522ffc7204a4b10854f5cc0531d2dc0fb9530fe1f54`
- Callback (Unichain, `SavingsVault.lock`): `0xb88fe068899654821e4e42ab034330e2a09112e66628070b9a6c1fedeeb1f001`

**Cron statement** — nobody involved, 2 s from tick to record
- Cron1000 tick handled on Lasna (block 8,150,001, 16:12:41 UTC+8): `0x07d43c3d83b9778f09bfa341168d3881cfaa63b0c0ef4500883fd46dd9bff314`
- Callback (Base, `Statement.record`, statement #2, 16:12:43): `0xbef443f06500e275a004c52a31f35485687d900cb5f7b77dcc8dbabee26053be`

The README lists every hop of the run (savings confirmations, the internal move, the on-demand
statement) and `deployments/e2e-latest.json` has the raw results.

## How it maps to the judging criteria

- **Execution:** deployed on Lasna, Base Sepolia and Unichain Sepolia; every loop above is real reactive
  transactions plus callbacks, re-runnable with one command (`python3 script/e2e.py`), which prints the
  hashes and latencies. Three independent deployments have each completed the full run.
- **Integration:** the reactive contract *is* the product — it holds the only cross-chain ledger, makes
  every decision, manages its own subscriptions at runtime, and uses events, callbacks to two chains and
  Cron together.
- **Usefulness:** a daily budget and automatic savings are things everyone wants; Ledgerline makes them
  work across chains without trusting a server or granting anything beyond a revocable ERC-20 approval
  to your own vault.
- **Craft:** 63 Foundry tests (unit, rules, callbacks, end-to-end with a mocked system contract and
  callback proxy, worst-case gas check), lint-clean Solidity, a resumable one-command deploy script, a
  live dashboard, and a README with architecture diagrams, costs and limitations.

## Team

moxi4096 (solo)
