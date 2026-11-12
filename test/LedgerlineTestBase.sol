// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test, Vm } from "forge-std/Test.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";

import { LedgerlineReactive } from "../src/LedgerlineReactive.sol";
import { SavingsVault } from "../src/SavingsVault.sol";
import { Statement } from "../src/Statement.sol";
import { LedgerToken } from "../src/LedgerToken.sol";
import { MockSystemContract } from "./mocks/MockSystemContract.sol";
import { MockCallbackProxy } from "./mocks/MockCallbackProxy.sol";

/// @notice Shared fixture: one EVM plays all three chains. Chain ids are labels carried in the log
///         records, exactly as Reactive Network delivers them.
abstract contract LedgerlineTestBase is Test {
    address internal constant SYSTEM = 0x8888888888888888888888888888888888888888;
    uint256 internal constant TRANSFER_TOPIC0 =
        0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;
    uint256 internal constant REACTIVE_IGNORE =
        0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    uint256 internal constant BASE = 84532; // Base Sepolia
    uint256 internal constant UNI = 1301; // Unichain Sepolia
    uint256 internal constant LASNA = 5318007;

    bytes32 internal constant USD = "USD";
    uint256 internal constant DAILY_LIMIT = 100e6; // 100 USD, 6 decimals
    uint16 internal constant SAVE_BPS = 1_000; // 10%
    uint256 internal constant MIN_INCOME = 1e6;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice"); // tracked wallet
    address internal aliceHot = makeAddr("aliceHot"); // second tracked wallet
    address internal shop = makeAddr("shop");
    address internal employer = makeAddr("employer");

    MockSystemContract internal sys;
    MockCallbackProxy internal baseProxy;
    MockCallbackProxy internal uniProxy;

    LedgerlineReactive internal ledger;
    LedgerToken internal usdBase;
    LedgerToken internal usdUni;
    SavingsVault internal vaultBase;
    SavingsVault internal vaultUni;
    Statement internal statement;

    uint256 internal nextTxHash = 1;

    function setUp() public virtual {
        vm.chainId(LASNA);
        vm.warp(1_794_000_000); // a fixed, realistic timestamp (Nov 2026)

        vm.etch(SYSTEM, address(new MockSystemContract()).code);
        sys = MockSystemContract(payable(SYSTEM));
        baseProxy = new MockCallbackProxy();
        uniProxy = new MockCallbackProxy();

        ledger = new LedgerlineReactive{ value: 1 ether }(owner);
        usdBase = new LedgerToken("Ledgerline Test USD", "lUSD", 6);
        usdUni = new LedgerToken("Ledgerline Test USD", "lUSD", 6);
        vaultBase = new SavingsVault(IPayable(payable(address(baseProxy))), address(ledger));
        vaultUni = new SavingsVault(IPayable(payable(address(uniProxy))), address(ledger));
        statement = new Statement(IPayable(payable(address(baseProxy))), address(ledger));
    }

    /// @dev The standard configuration used by most rule tests.
    function _configureDefault() internal {
        vm.startPrank(owner);
        ledger.configureAsset(USD, DAILY_LIMIT, SAVE_BPS, MIN_INCOME);
        ledger.trackWallet(alice);
        ledger.trackWallet(aliceHot);
        ledger.trackToken(BASE, address(usdBase), USD);
        ledger.trackToken(UNI, address(usdUni), USD);
        ledger.setVault(BASE, address(vaultBase));
        ledger.setVault(UNI, address(vaultUni));
        ledger.setStatementTarget(BASE, address(statement));
        vm.stopPrank();
        sys.clearRequests();
    }

    // --- log construction ---------------------------------------------------------------------------

    function _transferLog(uint256 chainId, address token, address from, address to, uint256 amount)
        internal
        returns (IReactive.LogRecord memory log_)
    {
        log_ = _transferLogAt(chainId, token, from, to, amount, nextTxHash++, 0);
    }

    function _transferLogAt(
        uint256 chainId,
        address token,
        address from,
        address to,
        uint256 amount,
        uint256 txHash,
        uint256 logIndex
    ) internal view returns (IReactive.LogRecord memory log_) {
        log_ = IReactive.LogRecord({
            chainId: chainId,
            contractAddress: token,
            topic0: TRANSFER_TOPIC0,
            topic1: uint256(uint160(from)),
            topic2: uint256(uint160(to)),
            topic3: 0,
            data: abi.encode(amount),
            blockNumber: block.number,
            opCode: 3,
            blockHash: 0,
            txHash: txHash,
            logIndex: logIndex
        });
    }

    function _cronLog(uint256 topic0) internal view returns (IReactive.LogRecord memory log_) {
        log_.chainId = LASNA;
        log_.contractAddress = ledger.CRON_SOURCE();
        log_.topic0 = topic0;
        log_.data = abi.encode(block.number);
        log_.opCode = 1;
        log_.blockNumber = block.number;
    }

    /// @dev Convert real `Transfer` logs recorded with `vm.recordLogs()` into Reactive log records.
    function _toLogRecords(Vm.Log[] memory logs, uint256 chainId)
        internal
        returns (IReactive.LogRecord[] memory out)
    {
        out = new IReactive.LogRecord[](logs.length);
        uint256 n;
        for (uint256 i = 0; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.topics.length != 3 || uint256(l.topics[0]) != TRANSFER_TOPIC0) continue;
            out[n++] = IReactive.LogRecord({
                chainId: chainId,
                contractAddress: l.emitter,
                topic0: uint256(l.topics[0]),
                topic1: uint256(l.topics[1]),
                topic2: uint256(l.topics[2]),
                topic3: 0,
                data: l.data,
                blockNumber: block.number,
                opCode: 3,
                blockHash: 0,
                txHash: nextTxHash++,
                logIndex: i
            });
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    // --- driving the network ------------------------------------------------------------------------

    function _react(IReactive.LogRecord memory log_) internal {
        vm.prank(SYSTEM);
        ledger.react(log_);
    }

    function _proxyFor(uint256 chainId) internal view returns (MockCallbackProxy) {
        if (chainId == BASE) return baseProxy;
        if (chainId == UNI) return uniProxy;
        revert("no proxy for chain");
    }

    /// @dev Deliver every pending callback through its chain's proxy; returns how many succeeded.
    function _deliverAll() internal returns (uint256 delivered) {
        uint256 n = sys.requestCount();
        for (uint256 i = 0; i < n; ++i) {
            MockSystemContract.Request memory r = sys.requestAt(i);
            (bool ok,) = _proxyFor(r.chainId).deliver(r.recipient, r.payload, r.requester);
            if (ok) ++delivered;
        }
        sys.clearRequests();
    }

    function _outKey(uint256 chainId, address token, address wallet) internal view returns (bytes32) {
        return sys.subscriptionKey(
            address(ledger),
            chainId,
            token,
            TRANSFER_TOPIC0,
            uint256(uint160(wallet)),
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    function _inKey(uint256 chainId, address token, address wallet) internal view returns (bytes32) {
        return sys.subscriptionKey(
            address(ledger),
            chainId,
            token,
            TRANSFER_TOPIC0,
            REACTIVE_IGNORE,
            uint256(uint160(wallet)),
            REACTIVE_IGNORE
        );
    }

    function _cronKey(uint256 topic0) internal view returns (bytes32) {
        return sys.subscriptionKey(
            address(ledger),
            LASNA,
            ledger.CRON_SOURCE(),
            topic0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    function _nextMidnight() internal view returns (uint256) {
        return (block.timestamp / 1 days + 1) * 1 days;
    }
}
