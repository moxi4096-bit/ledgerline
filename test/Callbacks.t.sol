// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { SavingsVault } from "../src/SavingsVault.sol";
import { Statement } from "../src/Statement.sol";
import { ISavingsVault, IStatement, StatementLine } from "../src/interfaces/ILedgerlineCallbacks.sol";
import { LedgerlineTestBase } from "./LedgerlineTestBase.sol";

/// @notice Destination contracts, driven through the mock callback proxy.
contract CallbacksTest is LedgerlineTestBase {
    bytes32 internal constant REF = keccak256("income-1");

    function setUp() public override {
        super.setUp();
        usdBase.mint(alice, 1_000e6);
    }

    function _sweep(uint256 amount, bytes32 ref) internal returns (bool ok) {
        (ok,) = baseProxy.deliver(
            address(vaultBase),
            abi.encodeCall(ISavingsVault.sweep, (address(0), address(usdBase), alice, amount, ref)),
            address(ledger)
        );
    }

    function _lock(uint256 until) internal returns (bool ok) {
        (ok,) = baseProxy.deliver(
            address(vaultBase),
            abi.encodeCall(ISavingsVault.lock, (address(0), USD, 120e6, 100e6, until)),
            address(ledger)
        );
    }

    // --- SavingsVault.sweep -------------------------------------------------------------------------

    function test_sweep_movesApprovedTokensIntoSavings() public {
        vm.prank(alice);
        usdBase.approve(address(vaultBase), type(uint256).max);

        vm.expectEmit(address(vaultBase));
        emit SavingsVault.Swept(REF, alice, address(usdBase), 25e6);
        assertTrue(_sweep(25e6, REF));

        assertEq(usdBase.balanceOf(address(vaultBase)), 25e6);
        assertEq(usdBase.balanceOf(alice), 975e6);
        assertEq(vaultBase.savingsOf(alice, address(usdBase)), 25e6);
        assertTrue(vaultBase.swept(REF));
    }

    function test_sweep_skipsWithoutAllowance() public {
        vm.expectEmit(address(vaultBase));
        emit SavingsVault.SweepSkipped(REF, alice, address(usdBase), 25e6, "allowance");
        assertTrue(_sweep(25e6, REF), "skipping is not a failure");
        assertEq(usdBase.balanceOf(alice), 1_000e6);
    }

    function test_sweep_skipsWithoutBalance() public {
        vm.prank(alice);
        usdBase.approve(address(vaultBase), type(uint256).max);
        vm.expectEmit(address(vaultBase));
        emit SavingsVault.SweepSkipped(REF, alice, address(usdBase), 2_000e6, "balance");
        assertTrue(_sweep(2_000e6, REF));
        assertEq(vaultBase.savingsOf(alice, address(usdBase)), 0);
    }

    function test_sweep_replayIsSkipped() public {
        vm.prank(alice);
        usdBase.approve(address(vaultBase), type(uint256).max);
        _sweep(25e6, REF);

        vm.expectEmit(address(vaultBase));
        emit SavingsVault.SweepSkipped(REF, alice, address(usdBase), 25e6, "duplicate");
        _sweep(25e6, REF);
        assertEq(vaultBase.savingsOf(alice, address(usdBase)), 25e6);
    }

    function test_sweep_rejectsDirectCalls() public {
        vm.expectRevert(
            abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), address(baseProxy))
        );
        vaultBase.sweep(address(ledger), address(usdBase), alice, 1, REF);
    }

    function test_sweep_rejectsOtherReactiveContracts() public {
        address impostor = makeAddr("impostor");
        (bool ok, bytes memory ret) = baseProxy.deliver(
            address(vaultBase),
            abi.encodeCall(ISavingsVault.sweep, (address(0), address(usdBase), alice, 1, REF)),
            impostor
        );
        assertFalse(ok);
        assertEq(
            ret,
            abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, impostor, address(ledger))
        );
    }

    // --- SavingsVault.lock / withdraw ---------------------------------------------------------------

    function test_lock_blocksWithdrawalsUntilMidnight() public {
        vm.prank(alice);
        usdBase.approve(address(vaultBase), type(uint256).max);
        _sweep(50e6, REF);

        uint256 until = _nextMidnight();
        vm.expectEmit(address(vaultBase));
        emit SavingsVault.BudgetLocked(USD, 120e6, 100e6, until);
        assertTrue(_lock(until));
        assertTrue(vaultBase.isLocked());

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SavingsVault.VaultLocked.selector, until));
        vaultBase.withdraw(address(usdBase), 10e6);

        vm.warp(until);
        assertFalse(vaultBase.isLocked());
        vm.prank(alice);
        vaultBase.withdraw(address(usdBase), 10e6);
        assertEq(usdBase.balanceOf(alice), 960e6);
        assertEq(vaultBase.savingsOf(alice, address(usdBase)), 40e6);
    }

    function test_lock_canOnlyBeExtended() public {
        uint256 later = block.timestamp + 2 days;
        _lock(later);
        _lock(block.timestamp + 1 hours);
        assertEq(vaultBase.lockedUntil(), later);
    }

    function test_lock_rejectsUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), address(baseProxy))
        );
        vaultBase.lock(address(ledger), USD, 0, 0, type(uint256).max);
    }

    function test_withdraw_onlyOwnSavings() public {
        vm.prank(alice);
        usdBase.approve(address(vaultBase), type(uint256).max);
        _sweep(50e6, REF);

        vm.prank(shop);
        vm.expectRevert(abi.encodeWithSelector(SavingsVault.InsufficientSavings.selector, 1, 0));
        vaultBase.withdraw(address(usdBase), 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SavingsVault.InsufficientSavings.selector, 51e6, 50e6));
        vaultBase.withdraw(address(usdBase), 51e6);
    }

    function test_vault_paysCallbackDebt() public {
        vm.deal(address(vaultBase), 1 ether);
        baseProxy.setDebt(address(vaultBase), 0.1 ether);
        assertTrue(baseProxy.charge(address(vaultBase)), "proxy-initiated pay()");
        assertEq(baseProxy.debt(address(vaultBase)), 0);

        baseProxy.setDebt(address(vaultBase), 0.2 ether);
        vaultBase.coverDebt(); // anyone can settle from the vault's own balance
        assertEq(baseProxy.debt(address(vaultBase)), 0);
        assertEq(address(vaultBase).balance, 0.7 ether);
    }

    // --- Statement ----------------------------------------------------------------------------------

    function _lines(uint256 totalIn) internal pure returns (StatementLine[] memory lines) {
        lines = new StatementLine[](2);
        lines[0] = StatementLine(USD, totalIn, 30e6, 30e6, 100e6, 20e6, 20e6);
        lines[1] = StatementLine("EURC", 0, 0, 0, 0, 0, 0);
    }

    function _record(uint256 seq, StatementLine[] memory lines) internal returns (bool ok) {
        (ok,) = baseProxy.deliver(
            address(statement),
            abi.encodeCall(IStatement.record, (address(0), seq, 1234, lines)),
            address(ledger)
        );
    }

    function test_statement_storesLatest() public {
        assertTrue(_record(1, _lines(200e6)));
        (uint256 seq, uint256 asOf, StatementLine[] memory lines) = statement.latest();
        assertEq(seq, 1);
        assertEq(asOf, 1234);
        assertEq(lines.length, 2);
        assertEq(lines[0].totalIn, 200e6);
        assertEq(lines[1].asset, bytes32("EURC"));

        StatementLine[] memory shorter = new StatementLine[](1);
        shorter[0] = StatementLine(USD, 300e6, 0, 0, 0, 0, 0);
        _record(2, shorter);
        (seq,, lines) = statement.latest();
        assertEq(seq, 2);
        assertEq(lines.length, 1, "old rows are cleared");
    }

    function test_statement_ignoresStaleSequence() public {
        _record(5, _lines(500e6));
        vm.expectEmit(address(statement));
        emit Statement.StaleStatementIgnored(4, 5);
        _record(4, _lines(400e6));
        (uint256 seq,, StatementLine[] memory lines) = statement.latest();
        assertEq(seq, 5);
        assertEq(lines[0].totalIn, 500e6);
    }

    function test_statement_rejectsUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), address(baseProxy))
        );
        statement.record(address(ledger), 1, 0, _lines(0));

        (bool ok,) = baseProxy.deliver(
            address(statement),
            abi.encodeCall(IStatement.record, (address(0), 1, 0, _lines(0))),
            makeAddr("impostor")
        );
        assertFalse(ok);
    }

    function test_statement_coverDebt() public {
        vm.deal(address(statement), 1 ether);
        baseProxy.setDebt(address(statement), 0.3 ether);
        statement.coverDebt();
        assertEq(baseProxy.debt(address(statement)), 0);
    }
}
