# Ledgerline

**One ledger for all your chains — and it runs itself.**

Ledgerline is a personal money tracker built on [Reactive Network](https://reactive.network). A single
reactive contract on Lasna watches your wallets' ERC-20 transfers on Base Sepolia and Unichain Sepolia,
keeps one cross-chain ledger, and acts on it:

| Rule | Trigger (origin) | Reactive logic (Lasna) | Callback (destination) |
| --- | --- | --- | --- |
| **Auto-save** | Income arrives in your wallet | 10% of it is earmarked | `SavingsVault.sweep` pulls it into savings **on the chain it arrived on** |
| **Budget guard** | You spend on *any* chain | Spending is summed across chains per UTC day | Over the limit → `SavingsVault.lock` freezes **every** vault until midnight |
| **Statements** | Reactive cron tick | Snapshot of every asset | `Statement.record` writes it to Base Sepolia |

There is no server, bot or keeper anywhere: every action starts from an on-chain event and ends in an
on-chain callback. Built for the [Reactive Omni Buildathon](https://dorahacks.io/hackathon/reactive-omni-buildathon/detail),
track **Set It and Forget It**.

**Repo:** https://github.com/moxi4096-bit/ledgerline · **Demo video (2:38):** [`demo/ledgerline-demo.mp4`](demo/ledgerline-demo.mp4)

> **Why it needs Reactive:** no contract on Base can see what you spent on Unichain. The cross-chain daily
> budget, and a lock that lands on every chain within seconds, only exist because a reactive contract
> sees all chains at once.

## Architecture

```mermaid
flowchart LR
    subgraph Base["Base Sepolia (origin + destination)"]
        BT["lUSD token<br/>Transfer events"]
        BV["SavingsVault"]
        ST["Statement"]
    end
    subgraph Uni["Unichain Sepolia (origin + destination)"]
        UT["lUSD token<br/>Transfer events"]
        UV["SavingsVault"]
    end
    subgraph Lasna["Reactive Lasna"]
        SYS["System contract<br/>0x8888…8888"]
        LR["LedgerlineReactive<br/>ledger · budget · savings"]
        CRON["Cron events"]
    end

    BT -- "Transfer(from/to = my wallet)" --> SYS
    UT -- "Transfer(from/to = my wallet)" --> SYS
    CRON --> SYS
    SYS -- "react(log)" --> LR
    LR -- "sweep (income on Base)" --> BV
    LR -- "sweep (income on Unichain)" --> UV
    LR -- "lock (budget exceeded)" --> BV
    LR -- "lock (budget exceeded)" --> UV
    LR -- "record (cron / on demand)" --> ST
```

A typical loop, end to end:

```mermaid
sequenceDiagram
    participant E as Employer (Base Sepolia)
    participant R as LedgerlineReactive (Lasna)
    participant V as SavingsVault (Base Sepolia)
    E->>E: lUSD.transfer(me, 500)
    Note over R: ~1–2 s later
    R->>R: react(): IncomeRecorded, SweepRequested(50)
    R-->>V: callback sweep(…, 50, ref)
    V->>V: transferFrom(me → vault, 50), Swept
    Note over R: the sweep's own Transfer comes back
    R->>R: react(): SavingsConfirmed(50)
```

### Subscriptions

For every tracked wallet *w* and token *t* on chain *c*, the reactive contract holds two subscriptions:

```
subscribe(c, t, Transfer, topic1 = w, *, *)   // money leaving w
subscribe(c, t, Transfer, *, topic2 = w, *)   // money arriving at w
```

Adding or removing a wallet or token (`trackWallet`, `untrackToken`, …) subscribes/unsubscribes exactly
those pairs at runtime. Filtering on the indexed wallet topic means you only pay for transfers that
involve you, and spam on the token never reaches the contract. Each log is de-duplicated by
`(chain, tx hash, log index)`, because a transfer between two of your own wallets matches two
subscriptions.

### Contracts

| Contract | Chain | Role |
| --- | --- | --- |
| [`LedgerlineReactive`](src/LedgerlineReactive.sol) | Lasna | Subscriptions, ledger, the three rules, callback requests |
| [`SavingsVault`](src/SavingsVault.sol) | Base Sepolia, Unichain Sepolia | `sweep` (opt-in via ERC-20 approval, replay-protected), `lock`, `withdraw` |
| [`Statement`](src/Statement.sol) | Base Sepolia | Stores the latest statement, emits every one, ignores out-of-order callbacks |
| [`LedgerToken`](src/LedgerToken.sol) | both | Mintable test stablecoin (lUSD, 6 decimals) for the demo |

Callback contracts inherit `AbstractCallback` and check both `onlyServiceProvider` (the chain's callback
proxy) and `onlyCallbackSender` (our reactive contract). Every callback payload reserves its first
argument for the reactive contract's address, which the network injects.

## Deployments (Lasna + testnets)

| | Address |
| --- | --- |
| LedgerlineReactive (Lasna) | [`0xfEafe4add13eB5a7c199dcDfD944b7A7F8276Fa9`](https://lasna.reactscan.net/address/0xfEafe4add13eB5a7c199dcDfD944b7A7F8276Fa9) |
| SavingsVault (Base Sepolia) | [`0x466CEdd72999181B14Afb9866AA056ea97fCD47d`](https://sepolia.basescan.org/address/0x466CEdd72999181B14Afb9866AA056ea97fCD47d) |
| Statement (Base Sepolia) | [`0x3c81Aa54515f197662Be1A8867D460C2df1BCf3F`](https://sepolia.basescan.org/address/0x3c81Aa54515f197662Be1A8867D460C2df1BCf3F) |
| lUSD (Base Sepolia) | [`0x4380B9171D3990178d0b0fc3eB585eAeBfe65146`](https://sepolia.basescan.org/address/0x4380B9171D3990178d0b0fc3eB585eAeBfe65146) |
| SavingsVault (Unichain Sepolia) | [`0x952527679b51cE7985FD260B9203A325857970A3`](https://sepolia.uniscan.xyz/address/0x952527679b51cE7985FD260B9203A325857970A3) |
| lUSD (Unichain Sepolia) | [`0x76cC901CD283f501DfCa802f20f18a0534696Fb9`](https://sepolia.uniscan.xyz/address/0x76cC901CD283f501DfCa802f20f18a0534696Fb9) |

This is the deployment shown in the demo video ([`deployments/testnet.json`](deployments/testnet.json)).
Earlier deployments of the same code, with their own full e2e runs, are kept in
[`deployments/testnet-v1.json`](deployments/testnet-v1.json) / [`e2e-v1-latest.json`](deployments/e2e-v1-latest.json)
and [`testnet-v2.json`](deployments/testnet-v2.json) / [`e2e-v2-latest.json`](deployments/e2e-v2-latest.json).
Statements on the canonical deployment run on **Cron10000** (about every 2.8 h); the older ones have cron turned off.

## Proof: full loops on-chain

| Loop | Origin tx | Reactive tx (Lasna) | Callback tx | Wall-clock latency |
| --- | --- | --- | --- | --- |
| auto-save on base-sepolia | [0xcb60540c…](https://sepolia.basescan.org/tx/0xcb60540cd53449c393ec65a2ceb37088512d66e890d47fd10128b50e470661ad) | [0xbda91cfe…](https://lasna.reactscan.net/tx/0xbda91cfe1eabc50a793af6cf635ca9b7b2dddc26542781b3b6d36a88232b9637) | [0xab566add…](https://sepolia.basescan.org/tx/0xab566add324aed4a2ff6196b6ee3cc2b1cdfd14e432feb084da81997fe0959bb) | 3.85 s |
| savings confirmed (base-sepolia) | [0xab566add…](https://sepolia.basescan.org/tx/0xab566add324aed4a2ff6196b6ee3cc2b1cdfd14e432feb084da81997fe0959bb) | [0xad4fe6f7…](https://lasna.reactscan.net/tx/0xad4fe6f7fdf291f21e0d5dd08252e38892136478fad5a23516f0fed60ec5a6e0) | — | 0.92 s |
| auto-save on unichain-sepolia | [0x156c4d2d…](https://sepolia.uniscan.xyz/tx/0x156c4d2da8ff7ae3f4df3077319a4b3a9957a136028e99ffe209beb7692da183) | [0x38566f01…](https://lasna.reactscan.net/tx/0x38566f01a42885e2adaaadaa0dfafc1a2a8ae52952a76f3d868ff76320f0c54a) | [0x3b91eb7d…](https://sepolia.uniscan.xyz/tx/0x3b91eb7d2cae2a473293547a9e9e8853e7253788ac90e65eb467e06c7cb44aec) | 5.32 s |
| savings confirmed (unichain-sepolia) | [0x3b91eb7d…](https://sepolia.uniscan.xyz/tx/0x3b91eb7d2cae2a473293547a9e9e8853e7253788ac90e65eb467e06c7cb44aec) | [0xa8a65ec9…](https://lasna.reactscan.net/tx/0xa8a65ec9abcdb643a1e5a18a7841726a9d56571b899692b84a2482283a251103) | — | 1.51 s |
| spend on unichain-sepolia | [0xb0463e0e…](https://sepolia.uniscan.xyz/tx/0xb0463e0e4cb6d11ee0878e04220762c9ad5a53989a7ffa7f902728d14e3447d1) | [0xdd4df858…](https://lasna.reactscan.net/tx/0xdd4df85879b5744643ef2f0f0018d070057a25cb43bbc5765398378deca4c125) | — | 3.17 s |
| budget lock: spend on base-sepolia -> lock on base-sepolia | [0xd6a0f32b…](https://sepolia.basescan.org/tx/0xd6a0f32b5284c3bfef33bf1acc5ada5ebc2fa430be998e5f7339bd9af7e20d65) | [0xe5848d39…](https://lasna.reactscan.net/tx/0xe5848d39b1ce07fef50d48762a3ef61d9378f1f5a4fe2ed61589b8607cc88cc9) | [0xc40856a3…](https://sepolia.basescan.org/tx/0xc40856a390a76a326d9e0522ffc7204a4b10854f5cc0531d2dc0fb9530fe1f54) | 3.05 s |
| budget lock: spend on base-sepolia -> lock on unichain-sepolia | [0xd6a0f32b…](https://sepolia.basescan.org/tx/0xd6a0f32b5284c3bfef33bf1acc5ada5ebc2fa430be998e5f7339bd9af7e20d65) | [0xe5848d39…](https://lasna.reactscan.net/tx/0xe5848d39b1ce07fef50d48762a3ef61d9378f1f5a4fe2ed61589b8607cc88cc9) | [0xb88fe068…](https://sepolia.uniscan.xyz/tx/0xb88fe068899654821e4e42ab034330e2a09112e66628070b9a6c1fedeeb1f001) | 3.54 s |
| internal move | [0xe7d0902f…](https://sepolia.basescan.org/tx/0xe7d0902f0511e859ea0f106eed1090b17505c6b643037ac76b37b736c483d7d8) | [0xf520c52e…](https://lasna.reactscan.net/tx/0xf520c52edfd4d461209c00e8f51ed3034aa3dea291cc2efaebb5c433ebbe7db2) | — | 1.11 s |
| statement (owner request on Lasna) | [0x657e9f93…](https://lasna.reactscan.net/tx/0x657e9f937426d19d45c7ab44cbe9ceb4944a6825ffc65d5d769dfc023d458bb1) | (same tx) | [0x005b099a…](https://sepolia.basescan.org/tx/0x005b099a33e8dc892865c3765a8f1b2d9fb4f49bcb5d0948e8c0829171852da8) | 2.5 s |
| **statement (Cron1000 tick, nobody involved)** | Lasna block 8,150,001 | [0x07d43c3d…](https://lasna.reactscan.net/tx/0x07d43c3d83b9778f09bfa341168d3881cfaa63b0c0ef4500883fd46dd9bff314) | [0xbef443f0…](https://sepolia.basescan.org/tx/0xbef443f06500e275a004c52a31f35485687d900cb5f7b77dcc8dbabee26053be) | 2 s (block time) |

Run 20261112T080701Z (the one recorded in the demo video). Latency is measured by [`script/e2e.py`](script/e2e.py): wall clock from the origin tx's receipt to the
first time the callback's log is visible over public RPC (polled every 0.3 s, so it includes RPC lag).
Block timestamps are recorded too, but they have 1 s resolution and the chains' clocks differ by up to a
second, so short hops can even show −1 s. The cron row uses block timestamps: tick on Lasna at
16:12:41, statement on Base Sepolia at 16:12:43 (UTC+8, 2026-11-12). Raw results: [`deployments/e2e-latest.json`](deployments/e2e-latest.json).

## Run it yourself

Requirements: [Foundry](https://getfoundry.sh), Python 3, testnet ETH on Ethereum Sepolia (bridge some
to Base/Unichain Sepolia; send some to the [Reactive faucet](https://dev.reactive.network/reactive-mainnet#get-testnet-react)
for lREACT).

```bash
git clone --recursive https://github.com/moxi4096-bit/ledgerline && cd ledgerline
forge test                        # 63 unit/integration tests with a mocked system contract
cp .env.example .env              # point KEY_FILE / PRIVATE_KEY at a testnet-only key
./script/deploy.sh                # deploys to Lasna, Base Sepolia, Unichain Sepolia and wires it up
python3 script/e2e.py             # fires real transactions and records every loop + latency
python3 -m http.server 8000       # then open http://localhost:8000/dashboard/
```

### Costs (testnet)

| | Per event | Notes |
| --- | --- | --- |
| Reactive tx on Lasna | ~0.03 lREACT | (gas used + 100k) × 100 gwei; worst case `react()` ≈ 245k gas |
| Callback on Base / Unichain | < 0.00001 ETH | billed to the callback contract in native ETH |
| Cron | ~0.02 lREACT per tick | Cron1000 ≈ every 17 min; use Cron10000 (~3 h) for daily statements |

## Tests

```bash
forge test -vv
forge coverage --ir-minimum
```

The suite etches a mock system contract at `0x8888…8888` and delivers callbacks through a mock proxy
that injects the sender address like the real one. It covers every rule path (spend, income, sweep,
dust, internal moves, duplicate logs, cross-chain budget, once-per-day lock, midnight reset, 80% warning,
cron schedule, statements), access control on every function, payment/debt handling, and a gas check that
the worst-case `react()` stays far below the network's 900k cap.

## Limitations and next steps

- One owner per deployment (it is a *personal* tool). A factory could deploy one per user.
- Daily budgets use UTC days. Time zones could be a per-asset offset.
- Savings stay on the chain they were earned on; there's no bridging.

## License

MIT
