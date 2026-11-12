// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

import { IStatement, StatementLine } from "./interfaces/ILedgerlineCallbacks.sol";

/// @title Statement
/// @notice Destination-chain record of Ledgerline's periodic statements: one row per asset with
///         cross-chain totals. The latest statement is kept in storage for cheap reads; every statement
///         is also emitted as an event, so the full history can be rebuilt from logs.
contract Statement is AbstractCallback, IStatement {
    uint256 public latestSeq;
    uint256 public latestAsOf;
    StatementLine[] internal _latestLines;

    event StatementRecorded(uint256 indexed seq, uint256 asOf, StatementLine[] lines);
    event StaleStatementIgnored(uint256 indexed seq, uint256 latestSeq);

    /// @param callbackProxy_ Reactive callback proxy on this chain.
    /// @param ledgerline_ The LedgerlineReactive contract allowed to send callbacks.
    constructor(IPayable callbackProxy_, address ledgerline_)
        payable
        AbstractCallback(callbackProxy_, ledgerline_)
    { }

    /// @inheritdoc IStatement
    function record(address rvm, uint256 seq, uint256 asOf, StatementLine[] calldata lines)
        external
        onlyServiceProvider
        onlyCallbackSender(rvm)
    {
        // Callbacks can land out of order; never let an older statement overwrite a newer one.
        if (seq <= latestSeq) {
            emit StaleStatementIgnored(seq, latestSeq);
            return;
        }
        latestSeq = seq;
        latestAsOf = asOf;

        delete _latestLines;
        for (uint256 i = 0; i < lines.length; ++i) {
            _latestLines.push(lines[i]);
        }
        emit StatementRecorded(seq, asOf, lines);
    }

    /// @notice The most recent statement.
    function latest() external view returns (uint256 seq, uint256 asOf, StatementLine[] memory lines) {
        return (latestSeq, latestAsOf, _latestLines);
    }

    /// @notice Settle any callback debt from this contract's ETH balance.
    function coverDebt() external {
        _coverDebt();
    }
}
