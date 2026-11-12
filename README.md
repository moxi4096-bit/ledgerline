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
| LedgerlineReactive (Lasna) | [`0xA3BC1c0544Dc29F4e1DC1DDD62dfED3D7B1aFd99`](https://lasna.reactscan.net/address/0xA3BC1c0544Dc29F4e1DC1DDD62dfED3D7B1aFd99) |
| SavingsVault (Base Sepolia) | [`0x21037C07bf16e1B9B5e76921bb075A75A6913809`](https://sepolia.basescan.org/address/0x21037C07bf16e1B9B5e76921bb075A75A6913809) |
| Statement (Base Sepolia) | [`0x77c5A276E32666eFC961A3fA3783A60fb1103c76`](https://sepolia.basescan.org/address/0x77c5A276E32666eFC961A3fA3783A60fb1103c76) |
| lUSD (Base Sepolia) | [`0xA3BC1c0544Dc29F4e1DC1DDD62dfED3D7B1aFd99`](https://sepolia.basescan.org/address/0xA3BC1c0544Dc29F4e1DC1DDD62dfED3D7B1aFd99) |
| SavingsVault (Unichain Sepolia) | [`0x21037C07bf16e1B9B5e76921bb075A75A6913809`](https://sepolia.uniscan.xyz/address/0x21037C07bf16e1B9B5e76921bb075A75A6913809) |
| lUSD (Unichain Sepolia) | [`0xA3BC1c0544Dc29F4e1DC1DDD62dfED3D7B1aFd99`](https://sepolia.uniscan.xyz/address/0xA3BC1c0544Dc29F4e1DC1DDD62dfED3D7B1aFd99) |

(The reactive contract and both lUSD tokens share an address because each was the deployer's first
transaction on its chain.)

## Proof: full loops on-chain

| Loop | Origin tx | Reactive tx (Lasna) | Callback tx | Wall-clock latency |
| --- | --- | --- | --- | --- |
| auto-save on base-sepolia | [0x9337473f…](https://sepolia.basescan.org/tx/0x9337473fd9eef9e64bcca01433fe8740fe89b1bfc293616e7a9d52b321bc02cd) | [0x4f0a8584…](https://lasna.reactscan.net/tx/0x4f0a858428495fdd080196f34243799de65286588eaef9e82af49bb3353c5d9a) | [0x99965095…](https://sepolia.basescan.org/tx/0x999650952b6dda9e0f3f2d19c8d63a2c88fda0738302066dffd6f3ae2df8462f) | 3.08 s |
| savings confirmed (base-sepolia) | [0x99965095…](https://sepolia.basescan.org/tx/0x999650952b6dda9e0f3f2d19c8d63a2c88fda0738302066dffd6f3ae2df8462f) | [0x70b920da…](https://lasna.reactscan.net/tx/0x70b920da6d1a79cd87e7d2d0d78e2fd856aa729ba6fbf9eb7e763231a9da02c8) | — | 1.06 s |
| auto-save on unichain-sepolia | [0x73891a65…](https://sepolia.uniscan.xyz/tx/0x73891a65021a064aae8244549b2d696160ae8bd288e9e35a0306ff0872692621) | [0xef994d97…](https://lasna.reactscan.net/tx/0xef994d975ec75633bba8935d9e64f1675689804ed50cbce6986fe3e99f063364) | [0x41f6dd11…](https://sepolia.uniscan.xyz/tx/0x41f6dd1187659dbbcca747c6aa8a442f15d9d547972fddd13a2ecdb424d02d2f) | 5.25 s |
| savings confirmed (unichain-sepolia) | [0x41f6dd11…](https://sepolia.uniscan.xyz/tx/0x41f6dd1187659dbbcca747c6aa8a442f15d9d547972fddd13a2ecdb424d02d2f) | [0xde041a85…](https://lasna.reactscan.net/tx/0xde041a85a1dd96270d955057db19790706ffb35de35267ff4b54fe0a635ea31b) | — | 1.55 s |
| spend on unichain-sepolia | [0x4789215a…](https://sepolia.uniscan.xyz/tx/0x4789215aff11e8ef554188dc97c19e4c04d1d2e983fe74d35bab472d21ec8247) | [0x00b7f22c…](https://lasna.reactscan.net/tx/0x00b7f22ce7ee0669725381a721051b50464a1dde8c448dd6d6e2b99012bf4b7b) | — | 5.7 s |
| budget lock: spend on base-sepolia -> lock on base-sepolia | [0x2406ee51…](https://sepolia.basescan.org/tx/0x2406ee514e9d6ceacaee952de9330b14b8b912dcdf63b9da64403cc5be7943ab) | [0x4284425b…](https://lasna.reactscan.net/tx/0x4284425be649c5c79abf10519a6e381fad5900605f05798132edf19410827e94) | [0xdf81246a…](https://sepolia.basescan.org/tx/0xdf81246a13da32edefa06320aa59877bad7b6af5156da7e6fe0a5bb4fdb97b22) | 3.16 s |
| budget lock: spend on base-sepolia -> lock on unichain-sepolia | [0x2406ee51…](https://sepolia.basescan.org/tx/0x2406ee514e9d6ceacaee952de9330b14b8b912dcdf63b9da64403cc5be7943ab) | [0x4284425b…](https://lasna.reactscan.net/tx/0x4284425be649c5c79abf10519a6e381fad5900605f05798132edf19410827e94) | [0x7a35cf67…](https://sepolia.uniscan.xyz/tx/0x7a35cf67d55245b50de7bcae88a00cb28f8434df2201bd066bc9d5797adef1e6) | 3.69 s |
| internal move | [0xcffa05ca…](https://sepolia.basescan.org/tx/0xcffa05cac435e42e2ba4c466dd37319bfd57bad64ef5419c2a40ddbf2aa5dfd9) | [0xe15c8bdc…](https://lasna.reactscan.net/tx/0xe15c8bdc4ff3d1f4c7b2bb4dddc9266ea7244cd2ad3be8a4751cd52a41295402) | — | 1.22 s |
| statement (owner request on Lasna) | [0xd47a6460…](https://lasna.reactscan.net/tx/0xd47a64607623e8d91f261b43b4268d70ea31d7c111160f5874c57c535adf2bcd) | (same tx) | [0xbb45aa91…](https://sepolia.basescan.org/tx/0xbb45aa91118e182a2d762548c660383b812f320199b5f6cd74a1d44b619a8560) | 2.53 s |

Run 20261112T075324Z. Latency is measured by [`script/e2e.py`](script/e2e.py): wall clock from the origin tx's receipt to the
first time the callback's log is visible over public RPC (polled every 0.3 s, so it includes RPC lag).
Block timestamps are recorded too, but they have 1 s resolution and the chains' clocks differ by up to a
second, so short hops can even show −1 s. Raw results: [`deployments/e2e-latest.json`](deployments/e2e-latest.json).

## Run it yourself

Requirements: [Foundry](https://getfoundry.sh), Python 3, testnet ETH on Ethereum Sepolia (bridge some
to Base/Unichain Sepolia; send some to the [Reactive faucet](https://dev.reactive.network/reactive-mainnet#get-testnet-react)
for lREACT).

```bash
git clone --recursive <this repo> && cd ledgerline
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
