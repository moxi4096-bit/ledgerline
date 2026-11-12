// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Vm } from "forge-std/Test.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { StatementLine } from "../src/interfaces/ILedgerlineCallbacks.sol";
import { LedgerlineTestBase } from "./LedgerlineTestBase.sol";

/// @notice The full loop with real token transfers: origin transfer -> react() -> callback delivered
///         through the proxy -> state change on the destination contract.
contract EndToEndTest is LedgerlineTestBase {
    function setUp() public override {
        super.setUp();
        _configureDefault();
        usdBase.mint(employer, 10_000e6);
        usdUni.mint(alice, 500e6);
        vm.prank(alice);
        usdBase.approve(address(vaultBase), type(uint256).max);
    }

    function _relay(uint256 chainId) internal {
        IReactive.LogRecord[] memory records = _toLogRecords(vm.getRecordedLogs(), chainId);
        for (uint256 i = 0; i < records.length; ++i) {
            _react(records[i]);
        }
    }

    function test_e2e_salaryIsAutoSavedOnBase() public {
        vm.recordLogs();
        vm.prank(employer);
        usdBase.transfer(alice, 1_000e6); // origin: payday on Base Sepolia
        _relay(BASE); // Reactive: income recorded, sweep requested

        assertEq(_deliverAll(), 1); // destination: sweep executed
        assertEq(vaultBase.savingsOf(alice, address(usdBase)), 100e6);
        assertEq(usdBase.balanceOf(alice), 900e6);
    }

    function test_e2e_sweepIsConfirmedAsSavingsNotSpending() public {
        vm.recordLogs();
        vm.prank(employer);
        usdBase.transfer(alice, 1_000e6);
        _relay(BASE);

        vm.recordLogs();
        _deliverAll(); // the sweep itself emits Transfer(alice -> vault) on Base...
        _relay(BASE); // ...which Reactive sees through alice's outgoing subscription

        assertEq(ledger.spentToday(0), 0, "saving is not spending");
        assertEq(ledger.asset(0).savedRequested, 100e6);
        assertEq(ledger.asset(0).savedConfirmed, 100e6);
    }

    function test_e2e_overspendingOnUnichainLocksTheBaseVault() public {
        // Save something first so there is something to lock.
        vm.recordLogs();
        vm.prank(employer);
        usdBase.transfer(alice, 500e6);
        _relay(BASE);
        _deliverAll();

        vm.recordLogs();
        vm.startPrank(alice);
        usdUni.transfer(shop, 70e6);
        usdUni.transfer(shop, 40e6); // 110 > 100 on Unichain
        vm.stopPrank();
        _relay(UNI);

        assertEq(_deliverAll(), 2, "both vaults locked");
        assertTrue(vaultBase.isLocked());
        assertTrue(vaultUni.isLocked());

        vm.prank(alice);
        vm.expectRevert();
        vaultBase.withdraw(address(usdBase), 1);
    }

    function test_e2e_statementLandsOnBase() public {
        vm.recordLogs();
        vm.prank(employer);
        usdBase.transfer(alice, 300e6);
        vm.prank(alice);
        usdBase.transfer(shop, 12e6);
        _relay(BASE);
        _deliverAll();

        uint256 cron = ledger.CRON1000_TOPIC0();
        vm.prank(owner);
        ledger.setStatementSchedule(cron, 0);
        _react(_cronLog(cron));
        assertEq(_deliverAll(), 1);

        (uint256 seq,, StatementLine[] memory lines) = statement.latest();
        assertEq(seq, 1);
        assertEq(lines[0].totalIn, 300e6);
        assertEq(lines[0].totalOut, 12e6, "relay above ran before the sweep was delivered");
        assertEq(lines[0].savedRequested, 30e6);
        assertEq(lines[0].savedConfirmed, 0, "sweep's own Transfer was not relayed in this test");
    }
}
