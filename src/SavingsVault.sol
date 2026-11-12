// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

import { ISavingsVault } from "./interfaces/ILedgerlineCallbacks.sol";

/// @title SavingsVault
/// @notice Destination-chain half of Ledgerline. Holds auto-saved tokens and enforces the budget lock.
///
/// - `sweep`: pulls a share of an income from the wallet into the vault. The wallet opts in by approving
///   the vault; without enough allowance or balance the sweep is skipped, never forced.
/// - `lock`: freezes withdrawals until the given time (next UTC midnight) after a budget overrun.
///
/// Both can only be triggered by Ledgerline's reactive contract, through this chain's callback proxy.
/// Savings belong to the wallet they were swept from, and only that wallet can withdraw them.
contract SavingsVault is AbstractCallback, ISavingsVault {
    using SafeERC20 for IERC20;

    /// @notice Savings per wallet and token.
    mapping(address wallet => mapping(address token => uint256)) public savingsOf;

    /// @notice Income transfers already swept (replay protection).
    mapping(bytes32 ref => bool) public swept;

    /// @notice Withdrawals are frozen until this timestamp.
    uint256 public lockedUntil;

    event Swept(bytes32 indexed ref, address indexed wallet, address indexed token, uint256 amount);
    event SweepSkipped(
        bytes32 indexed ref, address indexed wallet, address indexed token, uint256 amount, string reason
    );
    event BudgetLocked(bytes32 indexed asset, uint256 spentToday, uint256 dailyLimit, uint256 until);
    event Withdrawn(address indexed wallet, address indexed token, uint256 amount);

    error VaultLocked(uint256 until);
    error InsufficientSavings(uint256 requested, uint256 available);

    /// @param callbackProxy_ Reactive callback proxy on this chain.
    /// @param ledgerline_ The LedgerlineReactive contract on Reactive Network allowed to send callbacks.
    constructor(IPayable callbackProxy_, address ledgerline_)
        payable
        AbstractCallback(callbackProxy_, ledgerline_)
    { }

    /// @inheritdoc ISavingsVault
    function sweep(address rvm, address token, address wallet, uint256 amount, bytes32 ref)
        external
        onlyServiceProvider
        onlyCallbackSender(rvm)
    {
        if (swept[ref]) {
            emit SweepSkipped(ref, wallet, token, amount, "duplicate");
            return;
        }
        swept[ref] = true;

        IERC20 erc20 = IERC20(token);
        if (erc20.allowance(wallet, address(this)) < amount) {
            emit SweepSkipped(ref, wallet, token, amount, "allowance");
            return;
        }
        if (erc20.balanceOf(wallet) < amount) {
            emit SweepSkipped(ref, wallet, token, amount, "balance");
            return;
        }

        savingsOf[wallet][token] += amount;
        emit Swept(ref, wallet, token, amount);
        // The wallet opted in by approving this vault, and only Ledgerline can trigger a sweep.
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        erc20.safeTransferFrom(wallet, address(this), amount);
    }

    /// @inheritdoc ISavingsVault
    function lock(address rvm, bytes32 asset, uint256 spentToday, uint256 dailyLimit, uint256 until)
        external
        onlyServiceProvider
        onlyCallbackSender(rvm)
    {
        if (until > lockedUntil) lockedUntil = until; // a lock can only be extended, never shortened
        emit BudgetLocked(asset, spentToday, dailyLimit, until);
    }

    /// @notice Withdraw your own savings, unless a budget lock is active.
    function withdraw(address token, uint256 amount) external {
        if (isLocked()) revert VaultLocked(lockedUntil);
        uint256 available = savingsOf[msg.sender][token];
        if (amount > available) revert InsufficientSavings(amount, available);
        savingsOf[msg.sender][token] = available - amount;
        emit Withdrawn(msg.sender, token, amount);
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    function isLocked() public view returns (bool) {
        return block.timestamp < lockedUntil;
    }

    /// @notice Settle any callback debt from this contract's ETH balance. Anyone may call it; the funds
    ///         can only go to the callback proxy.
    function coverDebt() external {
        _coverDebt();
    }
}
