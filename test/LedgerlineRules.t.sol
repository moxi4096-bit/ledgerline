// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Vm } from "forge-std/Test.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { LedgerlineReactive } from "../src/LedgerlineReactive.sol";
import { ISavingsVault, IStatement, StatementLine } from "../src/interfaces/ILedgerlineCallbacks.sol";
import { MockSystemContract } from "./mocks/MockSystemContract.sol";
import { LedgerlineTestBase } from "./LedgerlineTestBase.sol";

/// @notice The three rules (budget guard, auto-save, statements) and log filtering, at the level of the
///         callbacks the reactive contract requests.
contract LedgerlineRulesTest is LedgerlineTestBase {
    function setUp() public override {
        super.setUp();
        _configureDefault();
    }

    // --- ledger -------------------------------------------------------------------------------------

    function test_spend_isRecordedPerTokenAndAsset() public {
        IReactive.LogRecord memory log_ = _transferLog(BASE, address(usdBase), alice, shop, 30e6);
        vm.expectEmit(address(ledger));
        emit LedgerlineReactive.SpendRecorded(log_.txHash, 0, alice, BASE, 30e6, 30e6);
        _react(log_);

        assertEq(ledger.tokenInfo(BASE, address(usdBase)).totalOut, 30e6);
        assertEq(ledger.asset(0).totalOut, 30e6);
        assertEq(ledger.spentToday(0), 30e6);
        assertEq(sys.requestCount(), 0, "under the limit: no callback");
    }

    function test_income_isRecordedAndSweepRequested() public {
        IReactive.LogRecord memory log_ = _transferLog(UNI, address(usdUni), employer, alice, 200e6);
        bytes32 ref = ledger.transferRef(UNI, log_.txHash, log_.logIndex);

        vm.expectEmit(address(ledger));
        emit LedgerlineReactive.IncomeRecorded(log_.txHash, 0, alice, UNI, 200e6);
        vm.expectEmit(address(ledger));
        emit LedgerlineReactive.SweepRequested(ref, UNI, alice, address(usdUni), 20e6);
        _react(log_);

        assertEq(ledger.tokenInfo(UNI, address(usdUni)).totalIn, 200e6);
        assertEq(ledger.asset(0).totalIn, 200e6);
        assertEq(ledger.asset(0).savedRequested, 20e6);

        assertEq(sys.requestCount(), 1);
        MockSystemContract.Request memory r = sys.requestAt(0);
        assertEq(r.chainId, UNI, "sweep happens on the chain the income arrived on");
        assertEq(r.recipient, address(vaultUni));
        assertEq(r.gasLimit, ledger.SWEEP_GAS());
        assertEq(
            r.payload, abi.encodeCall(ISavingsVault.sweep, (address(0), address(usdUni), alice, 20e6, ref))
        );
    }

    function test_income_belowMinimumIsNotSwept() public {
        _react(_transferLog(BASE, address(usdBase), employer, alice, MIN_INCOME - 1));
        assertEq(ledger.asset(0).totalIn, MIN_INCOME - 1, "still recorded");
        assertEq(sys.requestCount(), 0);
    }

    function test_income_notSweptWhenSavingsOff() public {
        vm.prank(owner);
        ledger.configureAsset(USD, DAILY_LIMIT, 0, MIN_INCOME);
        _react(_transferLog(BASE, address(usdBase), employer, alice, 50e6));
        assertEq(sys.requestCount(), 0);
    }

    function test_income_notSweptWithoutVaultOnThatChain() public {
        vm.prank(owner);
        ledger.setVault(BASE, address(0));
        _react(_transferLog(BASE, address(usdBase), employer, alice, 50e6));
        assertEq(ledger.asset(0).totalIn, 50e6);
        assertEq(sys.requestCount(), 0);
    }

    function test_income_tooSmallForAnyShareIsNotSwept() public {
        vm.prank(owner);
        ledger.configureAsset(USD, 0, 1, 0); // 0.01%
        _react(_transferLog(BASE, address(usdBase), employer, alice, 9_999)); // share rounds to 0
        assertEq(sys.requestCount(), 0);
        assertEq(ledger.asset(0).savedRequested, 0);
    }

    function testFuzz_income_sweepShare(uint96 amount, uint16 bps) public {
        bps = uint16(bound(bps, 1, ledger.MAX_SAVINGS_BPS()));
        vm.assume(amount >= MIN_INCOME);
        vm.prank(owner);
        ledger.configureAsset(USD, 0, bps, MIN_INCOME);

        _react(_transferLog(BASE, address(usdBase), employer, alice, amount));

        uint256 expected = (uint256(amount) * bps) / 10_000;
        assertEq(ledger.asset(0).savedRequested, expected);
        assertEq(sys.requestCount(), expected == 0 ? 0 : 1);
    }

    function test_internalMove_isNeitherSpendNorIncome() public {
        IReactive.LogRecord memory log_ = _transferLog(BASE, address(usdBase), alice, aliceHot, 40e6);
        vm.expectEmit(address(ledger));
        emit LedgerlineReactive.InternalMoveRecorded(log_.txHash, 0, BASE, 40e6);
        _react(log_);

        LedgerlineReactive.Token memory t = ledger.tokenInfo(BASE, address(usdBase));
        assertEq(t.internalMoves, 1);
        assertEq(t.totalIn + t.totalOut, 0);
        assertEq(ledger.spentToday(0), 0);
        assertEq(sys.requestCount(), 0);
    }

    function test_transferIntoVault_isConfirmedSavings() public {
        IReactive.LogRecord memory log_ =
            _transferLog(BASE, address(usdBase), alice, address(vaultBase), 25e6);
        vm.expectEmit(address(ledger));
        emit LedgerlineReactive.SavingsConfirmed(log_.txHash, 0, alice, BASE, 25e6);
        _react(log_);

        assertEq(ledger.asset(0).savedConfirmed, 25e6);
        assertEq(ledger.spentToday(0), 0);
        assertEq(ledger.asset(0).totalOut, 0);

        // The vault on the *other* chain is just an address here: a transfer to it on Base is spending.
        _react(_transferLog(BASE, address(usdBase), alice, address(vaultUni), 5e6));
        assertEq(ledger.spentToday(0), 5e6);
    }

    // --- filtering ----------------------------------------------------------------------------------

    function test_duplicateLog_isCountedOnce() public {
        // A transfer between two tracked wallets matches two subscriptions; the same applies to any
        // redelivery. The ledger must count it once.
        IReactive.LogRecord memory log_ = _transferLog(BASE, address(usdBase), alice, shop, 10e6);
        _react(log_);
        _react(log_);
        assertEq(ledger.asset(0).totalOut, 10e6);
        assertTrue(ledger.processed(ledger.transferRef(BASE, log_.txHash, log_.logIndex)));

        // Same tx, different log index = a different transfer.
        log_.logIndex = 1;
        _react(log_);
        assertEq(ledger.asset(0).totalOut, 20e6);
    }

    function test_irrelevantLogs_areIgnoredWithoutReverting() public {
        IReactive.LogRecord memory nft = _transferLog(BASE, address(usdBase), alice, shop, 1);
        nft.opCode = 4; // ERC-721 Transfer: same topic0, tokenId indexed
        _react(nft);

        IReactive.LogRecord memory otherEvent = _transferLog(BASE, address(usdBase), alice, shop, 1);
        otherEvent.topic0 = uint256(keccak256("Approval(address,address,uint256)"));
        _react(otherEvent);

        _react(_transferLog(BASE, address(0x1234), alice, shop, 1)); // untracked token
        _react(_transferLog(UNI, address(usdBase), alice, shop, 1)); // right token address, wrong chain
        _react(_transferLog(BASE, address(usdBase), shop, employer, 1)); // no tracked wallet

        assertEq(ledger.asset(0).totalOut + ledger.asset(0).totalIn, 0);
        assertEq(sys.requestCount(), 0);
    }

    function test_untrackedToken_stopsCounting() public {
        vm.prank(owner);
        ledger.untrackToken(BASE, address(usdBase));
        _react(_transferLog(BASE, address(usdBase), alice, shop, 10e6));
        assertEq(ledger.asset(0).totalOut, 0);
    }

    // --- budget guard -------------------------------------------------------------------------------

    function test_budget_crossChainSpendLocksEveryVault() public {
        _react(_transferLog(BASE, address(usdBase), alice, shop, 60e6));
        assertEq(sys.requestCount(), 0);

        uint256 until = _nextMidnight();
        vm.expectEmit(address(ledger));
        emit LedgerlineReactive.BudgetExceeded(0, 110e6, DAILY_LIMIT, until);
        _react(_transferLog(UNI, address(usdUni), aliceHot, shop, 50e6)); // 60 + 50 > 100, on another chain

        assertEq(sys.requestCount(), 2, "one lock per vault chain");
        for (uint256 i = 0; i < 2; ++i) {
            MockSystemContract.Request memory r = sys.requestAt(i);
            assertEq(r.recipient, r.chainId == BASE ? address(vaultBase) : address(vaultUni));
            assertEq(r.gasLimit, ledger.LOCK_GAS());
            assertEq(
                r.payload, abi.encodeCall(ISavingsVault.lock, (address(0), USD, 110e6, DAILY_LIMIT, until))
            );
        }
    }

    function test_budget_locksOncePerDay() public {
        _react(_transferLog(BASE, address(usdBase), alice, shop, 101e6));
        assertEq(sys.requestCount(), 2);
        sys.clearRequests();

        _react(_transferLog(BASE, address(usdBase), alice, shop, 5e6));
        assertEq(sys.requestCount(), 0, "already locked today");
        assertEq(ledger.spentToday(0), 106e6);
    }

    function test_budget_resetsAtUtcMidnight() public {
        _react(_transferLog(BASE, address(usdBase), alice, shop, 101e6));
        sys.clearRequests();

        vm.warp(_nextMidnight());
        assertEq(ledger.spentToday(0), 0, "view rolls over before any new spend");

        _react(_transferLog(BASE, address(usdBase), alice, shop, 40e6));
        assertEq(ledger.spentToday(0), 40e6);
        assertEq(sys.requestCount(), 0);

        _react(_transferLog(BASE, address(usdBase), alice, shop, 61e6));
        assertEq(sys.requestCount(), 2, "a new day can lock again");
    }

    function test_budget_exactlyAtLimitDoesNotLock() public {
        _react(_transferLog(BASE, address(usdBase), alice, shop, DAILY_LIMIT));
        assertEq(sys.requestCount(), 0);
    }

    function test_budget_warningAt80PercentFiresOnce() public {
        _react(_transferLog(BASE, address(usdBase), alice, shop, 70e6));

        vm.expectEmit(address(ledger));
        emit LedgerlineReactive.SpendWarning(0, 85e6, DAILY_LIMIT);
        _react(_transferLog(BASE, address(usdBase), alice, shop, 15e6)); // crosses 80%

        vm.recordLogs();
        _react(_transferLog(BASE, address(usdBase), alice, shop, 5e6)); // 90%: already warned
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != LedgerlineReactive.SpendWarning.selector, "warned twice");
        }
    }

    function test_budget_noLimitNeverLocks() public {
        vm.prank(owner);
        ledger.configureAsset(USD, 0, SAVE_BPS, MIN_INCOME);
        _react(_transferLog(BASE, address(usdBase), alice, shop, 1_000_000e6));
        assertEq(sys.requestCount(), 0);
    }

    function test_budget_noVaultsMeansAlertOnly() public {
        vm.startPrank(owner);
        ledger.setVault(BASE, address(0));
        ledger.setVault(UNI, address(0));
        vm.stopPrank();

        vm.expectEmit(address(ledger));
        emit LedgerlineReactive.BudgetExceeded(0, 150e6, DAILY_LIMIT, _nextMidnight());
        _react(_transferLog(BASE, address(usdBase), alice, shop, 150e6));
        assertEq(sys.requestCount(), 0);
    }

    // --- statements ---------------------------------------------------------------------------------

    function test_requestStatement_sendsAllAssets() public {
        vm.prank(owner);
        ledger.configureAsset("EURC", 0, 0, 0);
        _react(_transferLog(BASE, address(usdBase), employer, alice, 200e6));
        _react(_transferLog(UNI, address(usdUni), alice, shop, 30e6));
        sys.clearRequests();

        vm.prank(owner);
        ledger.requestStatement();

        assertEq(ledger.statementSeq(), 1);
        assertEq(sys.requestCount(), 1);
        MockSystemContract.Request memory r = sys.requestAt(0);
        assertEq(r.chainId, BASE);
        assertEq(r.recipient, address(statement));
        assertEq(r.gasLimit, ledger.STATEMENT_GAS());

        StatementLine[] memory lines = ledger.previewStatement();
        assertEq(lines.length, 2);
        assertEq(lines[0].asset, USD);
        assertEq(lines[0].totalIn, 200e6);
        assertEq(lines[0].totalOut, 30e6);
        assertEq(lines[0].spentToday, 30e6);
        assertEq(lines[0].dailyLimit, DAILY_LIMIT);
        assertEq(lines[0].savedRequested, 20e6);
        assertEq(lines[1].asset, bytes32("EURC"));
        assertEq(r.payload, abi.encodeCall(IStatement.record, (address(0), 1, block.timestamp, lines)));
    }

    function test_requestStatement_requiresTarget() public {
        LedgerlineReactive fresh = new LedgerlineReactive(owner);
        vm.prank(owner);
        vm.expectRevert(LedgerlineReactive.StatementTargetMissing.selector);
        fresh.requestStatement();
    }

    function test_preview_spentTodayRollsOver() public {
        _react(_transferLog(BASE, address(usdBase), alice, shop, 30e6));
        vm.warp(block.timestamp + 1 days);
        assertEq(ledger.previewStatement()[0].spentToday, 0);
        assertEq(ledger.previewStatement()[0].totalOut, 30e6);
    }

    function test_cron_postsOnlyAfterInterval() public {
        uint256 topic = ledger.CRON1000_TOPIC0();
        vm.prank(owner);
        ledger.setStatementSchedule(topic, 1 hours);

        _react(_cronLog(topic));
        assertEq(sys.requestCount(), 0, "too early");

        vm.warp(block.timestamp + 1 hours);
        _react(_cronLog(topic));
        assertEq(sys.requestCount(), 1);
        assertEq(ledger.statementSeq(), 1);
        assertEq(ledger.nextStatementAt(), block.timestamp + 1 hours);

        _react(_cronLog(topic));
        assertEq(sys.requestCount(), 1, "next one waits a full interval");
    }

    function test_cron_otherFeedsAndDisabledScheduleAreIgnored() public {
        uint256 c1000 = ledger.CRON1000_TOPIC0();
        uint256 c100 = ledger.CRON100_TOPIC0();
        vm.warp(block.timestamp + 365 days);
        _react(_cronLog(c1000)); // schedule off
        assertEq(sys.requestCount(), 0);

        vm.prank(owner);
        ledger.setStatementSchedule(c1000, 0);
        _react(_cronLog(c100)); // a feed we did not choose
        assertEq(sys.requestCount(), 0);

        IReactive.LogRecord memory spoof = _cronLog(c1000);
        spoof.contractAddress = address(0xbad); // right topic, wrong emitter
        _react(spoof);
        assertEq(sys.requestCount(), 0);

        _react(_cronLog(c1000));
        assertEq(sys.requestCount(), 1);
    }

    // --- gas ----------------------------------------------------------------------------------------

    /// @dev Reactive transactions are capped at 900k gas and the system contract keeps 100k of that
    ///      (`_extraGas`), so `react()` itself must stay well under 800k in the worst case.
    function test_gas_worstCaseReactStaysUnderNetworkCap() public {
        vm.startPrank(owner);
        for (uint256 i = 1; i < ledger.MAX_ASSETS(); ++i) {
            ledger.configureAsset(bytes32(i), 1, 0, 0);
        }
        for (uint256 i = 2; i < ledger.MAX_VAULTS(); ++i) {
            ledger.setVault(10_000 + i, address(uint160(0x5000 + i)));
        }
        ledger.setStatementSchedule(ledger.CRON100_TOPIC0(), 0);
        vm.stopPrank();
        sys.setEmitOnly(true);

        // Budget overrun fanning out to the maximum number of vaults.
        IReactive.LogRecord memory spend = _transferLog(BASE, address(usdBase), alice, shop, 500e6);
        vm.prank(SYSTEM);
        uint256 g = gasleft();
        ledger.react(spend);
        uint256 lockGas = g - gasleft();

        // Statement covering the maximum number of assets.
        IReactive.LogRecord memory tick = _cronLog(ledger.CRON100_TOPIC0());
        vm.prank(SYSTEM);
        g = gasleft();
        ledger.react(tick);
        uint256 statementGas = g - gasleft();

        emit log_named_uint("react gas, lock fan-out x4", lockGas);
        emit log_named_uint("react gas, statement x8 assets", statementGas);
        assertLt(lockGas, 500_000);
        assertLt(statementGas, 500_000);
    }
}
