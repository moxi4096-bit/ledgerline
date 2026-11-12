// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice One row of a periodic statement: the cross-chain totals for a single asset.
struct StatementLine {
    bytes32 asset; // e.g. "USDC"; the same asset can live on several chains
    uint256 totalIn; // all-time income, summed across chains
    uint256 totalOut; // all-time spending, summed across chains
    uint256 spentToday; // spending during the current UTC day
    uint256 dailyLimit; // 0 = no limit
    uint256 savedRequested; // all-time amount Ledgerline asked the vaults to sweep
    uint256 savedConfirmed; // all-time amount actually observed moving into the vaults
}

/// @title Callback surface of SavingsVault.
/// @dev The first argument of every callback is the reactive contract's address. Ledgerline encodes
///      `address(0)` there and Reactive Network overwrites it before delivery, so the destination can
///      check who requested the callback.
interface ISavingsVault {
    /// @notice Move `amount` of `token` from `wallet` into the vault (the wallet approved the vault).
    /// @param ref Unique id of the income transfer that triggered the sweep, used for replay protection.
    function sweep(address rvm, address token, address wallet, uint256 amount, bytes32 ref) external;

    /// @notice Freeze withdrawals until `until` because `asset` went over its daily budget.
    function lock(address rvm, bytes32 asset, uint256 spentToday, uint256 dailyLimit, uint256 until) external;
}

/// @title Callback surface of Statement.
interface IStatement {
    /// @notice Store a statement snapshot. `seq` increases by one per statement.
    function record(address rvm, uint256 seq, uint256 asOf, StatementLine[] calldata lines) external;
}
