// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

import { ISavingsVault, IStatement, StatementLine } from "./interfaces/ILedgerlineCallbacks.sol";

/// @title LedgerlineReactive
/// @notice A personal, cross-chain money ledger that runs itself on Reactive Network.
///
/// It watches ERC-20 `Transfer` events for the owner's wallets on every configured chain and keeps one
/// ledger for all of them. Three rules act on that ledger through callbacks:
///
///  1. Budget guard: when spending of an asset (summed across chains) passes its daily limit, every
///     SavingsVault is locked until the next UTC midnight.
///  2. Auto-save: when income arrives, a share of it is swept into the SavingsVault on that chain.
///  3. Statements: on a Reactive cron tick (or on demand) a snapshot of all assets is written to the
///     Statement contract.
///
/// Wallets and tokens can be added or removed at any time; the contract updates its subscriptions to
/// match. No keepers and no servers: every action starts from an on-chain event.
contract LedgerlineReactive is AbstractReactive {
    // ------------------------------------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------------------------------------

    /// @notice keccak256("Transfer(address,address,uint256)")
    uint256 public constant TRANSFER_TOPIC0 =
        0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    /// @notice Emitter of the network's Cron events (the legacy system contract).
    address public constant CRON_SOURCE = 0x0000000000000000000000000000000000fffFfF;
    uint256 public constant CRON100_TOPIC0 =
        0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;
    uint256 public constant CRON1000_TOPIC0 =
        0xe20b31294d84c3661ddc8f423abb9c70310d0cf172aa2714ead78029b325e3f4;
    uint256 public constant CRON10000_TOPIC0 =
        0xd214e1d84db704ed42d37f538ea9bf71e44ba28bc1cc088b2f5deca654677a56;

    /// @notice Gas limits for each callback. Reactive Network ignores requests below 100,000, and the
    ///         destination proxy keeps ~130k of the limit for its own accounting.
    uint64 public constant SWEEP_GAS = 400_000;
    uint64 public constant LOCK_GAS = 300_000;
    uint64 public constant STATEMENT_GAS = 1_500_000;

    /// @notice Bounds that keep every loop (and therefore every reactive transaction) well under the
    ///         network's 900k gas cap.
    uint256 public constant MAX_WALLETS = 5;
    uint256 public constant MAX_TOKENS = 12;
    uint256 public constant MAX_ASSETS = 8;
    uint256 public constant MAX_VAULTS = 4;

    uint16 public constant MAX_SAVINGS_BPS = 5_000; // never sweep more than half of an income

    // ------------------------------------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------------------------------------

    /// @notice An asset groups the same currency across chains, e.g. USDC on Base and on Unichain.
    struct Asset {
        bytes32 symbol;
        uint256 dailyLimit; // 0 = no limit
        uint16 savingsBps; // share of each income to sweep, in basis points; 0 = off
        uint256 minIncome; // incomes below this are not swept (ignores dust)
        uint256 totalIn;
        uint256 totalOut;
        uint256 spentToday;
        uint256 spentDay; // UTC day number `spentToday` refers to
        uint256 lockedDay; // UTC day the budget lock was last sent
        uint256 savedRequested; // asked the vaults to sweep
        uint256 savedConfirmed; // sweeps actually observed on-chain (wallet -> vault transfers)
    }

    /// @notice One ERC-20 contract on one chain, mapped to an asset.
    struct Token {
        uint256 chainId;
        address token;
        uint256 assetId; // index into `assets`
        bool active;
        uint256 totalIn;
        uint256 totalOut;
        uint256 internalMoves; // transfers between two of the owner's own wallets
    }

    // ------------------------------------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------------------------------------

    address public immutable owner;

    Asset[] internal _assets;
    mapping(bytes32 symbol => uint256 idPlusOne) internal _assetIdOf;

    bytes32[] internal _tokenKeys;
    mapping(bytes32 key => Token) internal _tokens;
    uint256 public activeTokenCount;

    address[] internal _wallets;
    mapping(address wallet => bool) public isWallet;

    uint256[] internal _vaultChains;
    mapping(uint256 chainId => address vault) public vaultOf;

    uint256 public statementChainId;
    address public statementRecipient;
    uint256 public statementSeq;

    uint256 public statementCronTopic; // 0 = scheduled statements off
    uint256 public statementInterval;
    uint256 public nextStatementAt;

    /// @notice Transfers already counted, keyed by (chain, tx hash, log index). Guards against the same
    ///         log arriving twice, e.g. a transfer between two tracked wallets matches two subscriptions.
    mapping(bytes32 ref => bool) public processed;

    // ------------------------------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------------------------------

    event AssetConfigured(
        uint256 indexed assetId, bytes32 symbol, uint256 dailyLimit, uint16 savingsBps, uint256 minIncome
    );
    event TokenTracked(bytes32 indexed key, uint256 indexed chainId, address indexed token, uint256 assetId);
    event TokenUntracked(bytes32 indexed key, uint256 indexed chainId, address indexed token);
    event WalletTracked(address indexed wallet);
    event WalletUntracked(address indexed wallet);
    event VaultSet(uint256 indexed chainId, address vault);
    event StatementTargetSet(uint256 indexed chainId, address recipient);
    event StatementScheduleSet(uint256 cronTopic, uint256 interval);

    event SpendRecorded(
        uint256 indexed originTxHash,
        uint256 indexed assetId,
        address indexed wallet,
        uint256 chainId,
        uint256 amount,
        uint256 spentToday
    );
    event IncomeRecorded(
        uint256 indexed originTxHash,
        uint256 indexed assetId,
        address indexed wallet,
        uint256 chainId,
        uint256 amount
    );
    event InternalMoveRecorded(
        uint256 indexed originTxHash, uint256 indexed assetId, uint256 chainId, uint256 amount
    );
    event SavingsConfirmed(
        uint256 indexed originTxHash,
        uint256 indexed assetId,
        address indexed wallet,
        uint256 chainId,
        uint256 amount
    );
    event SpendWarning(uint256 indexed assetId, uint256 spentToday, uint256 dailyLimit);
    event BudgetExceeded(
        uint256 indexed assetId, uint256 spentToday, uint256 dailyLimit, uint256 lockedUntil
    );
    event SweepRequested(
        bytes32 indexed ref, uint256 indexed chainId, address wallet, address token, uint256 amount
    );
    event StatementRequested(uint256 indexed seq, uint256 asOf, uint256 lines);

    // ------------------------------------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------------------------------------

    error NotOwner();
    error LimitReached();
    error AlreadyTracked();
    error NotTracked();
    error UnknownAsset();
    error InvalidConfig();
    error StatementTargetMissing();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param owner_ Account allowed to configure the ledger.
    /// @dev `payable` so the contract can be funded with REACT at deployment.
    constructor(address owner_) payable {
        if (owner_ == address(0)) revert InvalidConfig();
        owner = owner_;
    }

    // ================================================================================================
    // Reactive entry point
    // ================================================================================================

    /// @inheritdoc IReactive
    /// @dev Never reverts on unexpected input: a revert is still billed, so unknown logs just fall through.
    function react(LogRecord calldata log_) external onlySystem {
        if (log_.topic0 == TRANSFER_TOPIC0 && log_.opCode == 3) {
            _onTransfer(log_);
        } else if (
            log_.contractAddress == CRON_SOURCE && statementCronTopic != 0
                && log_.topic0 == statementCronTopic
        ) {
            _onCronTick();
        }
    }

    // ================================================================================================
    // Configuration (owner, called directly on Reactive Network)
    // ================================================================================================

    /// @notice Create an asset or update its rules. Existing totals are kept.
    function configureAsset(bytes32 symbol, uint256 dailyLimit, uint16 savingsBps, uint256 minIncome)
        external
        onlyOwner
        returns (uint256 assetId)
    {
        if (symbol == bytes32(0) || savingsBps > MAX_SAVINGS_BPS) revert InvalidConfig();
        uint256 idPlusOne = _assetIdOf[symbol];
        if (idPlusOne == 0) {
            if (_assets.length == MAX_ASSETS) revert LimitReached();
            _assets.push();
            idPlusOne = _assets.length;
            _assetIdOf[symbol] = idPlusOne;
        }
        assetId = idPlusOne - 1;
        Asset storage a = _assets[assetId];
        a.symbol = symbol;
        a.dailyLimit = dailyLimit;
        a.savingsBps = savingsBps;
        a.minIncome = minIncome;
        emit AssetConfigured(assetId, symbol, dailyLimit, savingsBps, minIncome);
    }

    /// @notice Start watching `token` on `chainId` as part of an asset, for every tracked wallet.
    function trackToken(uint256 chainId, address token, bytes32 assetSymbol) external onlyOwner {
        uint256 idPlusOne = _assetIdOf[assetSymbol];
        if (idPlusOne == 0) revert UnknownAsset();
        if (chainId == 0 || token == address(0)) revert InvalidConfig();

        bytes32 key = tokenKey(chainId, token);
        Token storage t = _tokens[key];
        if (t.active) revert AlreadyTracked();
        if (t.token == address(0)) {
            if (_tokenKeys.length == MAX_TOKENS) revert LimitReached();
            _tokenKeys.push(key);
            t.chainId = chainId;
            t.token = token;
        }
        t.assetId = idPlusOne - 1; // a re-tracked token keeps its history
        t.active = true;
        ++activeTokenCount;

        emit TokenTracked(key, chainId, token, t.assetId);
        for (uint256 i = 0; i < _wallets.length; ++i) {
            _subscribePair(chainId, token, _wallets[i]);
        }
    }

    /// @notice Stop watching a token. Its ledger history stays readable.
    function untrackToken(uint256 chainId, address token) external onlyOwner {
        bytes32 key = tokenKey(chainId, token);
        Token storage t = _tokens[key];
        if (!t.active) revert NotTracked();
        t.active = false;
        --activeTokenCount;

        emit TokenUntracked(key, chainId, token);
        for (uint256 i = 0; i < _wallets.length; ++i) {
            _unsubscribePair(chainId, token, _wallets[i]);
        }
    }

    /// @notice Start watching a wallet on every tracked token. EVM addresses are the same on every chain.
    function trackWallet(address wallet) external onlyOwner {
        if (wallet == address(0)) revert InvalidConfig();
        if (isWallet[wallet]) revert AlreadyTracked();
        if (_wallets.length == MAX_WALLETS) revert LimitReached();
        isWallet[wallet] = true;
        _wallets.push(wallet);
        emit WalletTracked(wallet);

        for (uint256 i = 0; i < _tokenKeys.length; ++i) {
            Token storage t = _tokens[_tokenKeys[i]];
            if (t.active) _subscribePair(t.chainId, t.token, wallet);
        }
    }

    /// @notice Stop watching a wallet.
    function untrackWallet(address wallet) external onlyOwner {
        if (!isWallet[wallet]) revert NotTracked();
        isWallet[wallet] = false;
        emit WalletUntracked(wallet);

        uint256 last = _wallets.length - 1;
        for (uint256 i = 0; i <= last; ++i) {
            if (_wallets[i] == wallet) {
                _wallets[i] = _wallets[last];
                _wallets.pop();
                break;
            }
        }

        for (uint256 i = 0; i < _tokenKeys.length; ++i) {
            Token storage t = _tokens[_tokenKeys[i]];
            if (t.active) _unsubscribePair(t.chainId, t.token, wallet);
        }
    }

    /// @notice Set (or clear, with `vault == address(0)`) the SavingsVault for a chain.
    function setVault(uint256 chainId, address vault) external onlyOwner {
        if (chainId == 0) revert InvalidConfig();
        bool known = vaultOf[chainId] != address(0);
        if (vault != address(0) && !known) {
            if (_vaultChains.length == MAX_VAULTS) revert LimitReached();
            _vaultChains.push(chainId);
        } else if (vault == address(0) && known) {
            _removeVaultChain(chainId);
        }
        vaultOf[chainId] = vault;
        emit VaultSet(chainId, vault);
    }

    /// @notice Where statements are written.
    function setStatementTarget(uint256 chainId, address recipient) external onlyOwner {
        if (chainId == 0 || recipient == address(0)) revert InvalidConfig();
        statementChainId = chainId;
        statementRecipient = recipient;
        emit StatementTargetSet(chainId, recipient);
    }

    /// @notice Choose the cron feed that drives statements and the minimum time between two of them.
    /// @param cronTopic One of the CRON*_TOPIC0 constants, or 0 to switch scheduled statements off.
    /// @dev Every cron tick is billed, so pick the slowest feed that fits the interval.
    function setStatementSchedule(uint256 cronTopic, uint256 interval) external onlyOwner {
        if (
            cronTopic != 0 && cronTopic != CRON100_TOPIC0 && cronTopic != CRON1000_TOPIC0
                && cronTopic != CRON10000_TOPIC0
        ) {
            revert InvalidConfig();
        }
        uint256 previous = statementCronTopic;
        statementCronTopic = cronTopic;
        statementInterval = interval;
        nextStatementAt = block.timestamp + interval;
        emit StatementScheduleSet(cronTopic, interval);

        if (previous != 0) {
            SYSTEM.unsubscribe(
                block.chainid, CRON_SOURCE, previous, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
        }
        if (cronTopic != 0) {
            SYSTEM.subscribe(
                block.chainid, CRON_SOURCE, cronTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
        }
    }

    /// @notice Write a statement now instead of waiting for the next cron tick.
    function requestStatement() external onlyOwner {
        _postStatement();
    }

    /// @notice Settle any debt to the system contract from this contract's balance, reactivating it.
    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Withdraw unused REACT.
    function withdraw(address payable to, uint256 amount) external onlyOwner {
        _pay(to, amount);
    }

    // ================================================================================================
    // Views
    // ================================================================================================

    function tokenKey(uint256 chainId, address token) public pure returns (bytes32) {
        return keccak256(abi.encode(chainId, token));
    }

    function transferRef(uint256 chainId, uint256 txHash, uint256 logIndex) public pure returns (bytes32) {
        return keccak256(abi.encode(chainId, txHash, logIndex));
    }

    function assetCount() external view returns (uint256) {
        return _assets.length;
    }

    function asset(uint256 assetId) external view returns (Asset memory) {
        return _assets[assetId];
    }

    function assetIdOf(bytes32 symbol) external view returns (uint256) {
        uint256 idPlusOne = _assetIdOf[symbol];
        if (idPlusOne == 0) revert UnknownAsset();
        return idPlusOne - 1;
    }

    function tokenCount() external view returns (uint256) {
        return _tokenKeys.length;
    }

    function tokenAt(uint256 index) external view returns (Token memory) {
        return _tokens[_tokenKeys[index]];
    }

    function tokenInfo(uint256 chainId, address token) external view returns (Token memory) {
        return _tokens[tokenKey(chainId, token)];
    }

    function wallets() external view returns (address[] memory) {
        return _wallets;
    }

    function vaultChains() external view returns (uint256[] memory) {
        return _vaultChains;
    }

    /// @notice Spending of an asset during the current UTC day.
    function spentToday(uint256 assetId) public view returns (uint256) {
        Asset storage a = _assets[assetId];
        return a.spentDay == _today() ? a.spentToday : 0;
    }

    /// @notice The statement that would be written right now.
    function previewStatement() public view returns (StatementLine[] memory lines) {
        lines = new StatementLine[](_assets.length);
        for (uint256 i = 0; i < _assets.length; ++i) {
            Asset storage a = _assets[i];
            lines[i] = StatementLine({
                asset: a.symbol,
                totalIn: a.totalIn,
                totalOut: a.totalOut,
                spentToday: spentToday(i),
                dailyLimit: a.dailyLimit,
                savedRequested: a.savedRequested,
                savedConfirmed: a.savedConfirmed
            });
        }
    }

    // ================================================================================================
    // Rules
    // ================================================================================================

    function _onTransfer(LogRecord calldata log_) internal {
        Token storage t = _tokens[tokenKey(log_.chainId, log_.contractAddress)];
        if (!t.active) return;

        bytes32 ref = transferRef(log_.chainId, log_.txHash, log_.logIndex);
        if (processed[ref]) return;

        // Indexed address topics are left-padded 20-byte values, so the cast is lossless.
        // forge-lint: disable-next-line(unsafe-typecast)
        address from = address(uint160(log_.topic1));
        // forge-lint: disable-next-line(unsafe-typecast)
        address to = address(uint160(log_.topic2));
        bool fromMine = isWallet[from];
        bool toMine = isWallet[to];
        if (!fromMine && !toMine) return; // e.g. a wallet removed while the log was in flight

        processed[ref] = true;
        uint256 amount = abi.decode(log_.data, (uint256));
        Asset storage a = _assets[t.assetId];

        if (fromMine && to == vaultOf[log_.chainId]) {
            // The vault pulling a sweep: money moved into savings, not spent. (The vault's own Transfer
            // events only reach us because the wallet is in topic1, so no extra subscription is needed.)
            a.savedConfirmed += amount;
            emit SavingsConfirmed(log_.txHash, t.assetId, from, log_.chainId, amount);
        } else if (fromMine && toMine) {
            ++t.internalMoves;
            emit InternalMoveRecorded(log_.txHash, t.assetId, log_.chainId, amount);
        } else if (fromMine) {
            t.totalOut += amount;
            a.totalOut += amount;
            _applyBudget(a, t.assetId, from, log_, amount);
        } else {
            t.totalIn += amount;
            a.totalIn += amount;
            emit IncomeRecorded(log_.txHash, t.assetId, to, log_.chainId, amount);
            _applySavings(a, t, to, ref, amount);
        }
    }

    /// @dev Rule 1: budget guard.
    function _applyBudget(
        Asset storage a,
        uint256 assetId,
        address wallet,
        LogRecord calldata log_,
        uint256 amount
    ) internal {
        uint256 today = _today();
        if (a.spentDay != today) {
            a.spentDay = today;
            a.spentToday = 0;
        }
        uint256 spent = a.spentToday + amount;
        a.spentToday = spent;
        emit SpendRecorded(log_.txHash, assetId, wallet, log_.chainId, amount, spent);

        uint256 limit = a.dailyLimit;
        if (limit == 0) return;

        if (spent > limit) {
            if (a.lockedDay == today) return; // already locked today
            a.lockedDay = today;
            uint256 until = (today + 1) * 1 days; // next UTC midnight
            emit BudgetExceeded(assetId, spent, limit, until);
            for (uint256 i = 0; i < _vaultChains.length; ++i) {
                uint256 chainId = _vaultChains[i];
                _callback(
                    chainId,
                    vaultOf[chainId],
                    LOCK_GAS,
                    abi.encodeCall(ISavingsVault.lock, (address(0), a.symbol, spent, limit, until))
                );
            }
        } else if (spent * 5 >= limit * 4 && (spent - amount) * 5 < limit * 4) {
            emit SpendWarning(assetId, spent, limit); // this transfer crossed 80% of the limit
        }
    }

    /// @dev Rule 2: auto-save a share of each income on the chain where it arrived.
    function _applySavings(Asset storage a, Token storage t, address wallet, bytes32 ref, uint256 amount)
        internal
    {
        if (a.savingsBps == 0 || amount == 0 || amount < a.minIncome) return;
        address vault = vaultOf[t.chainId];
        if (vault == address(0)) return;

        uint256 toSave = (amount * a.savingsBps) / 10_000;
        if (toSave == 0) return;
        a.savedRequested += toSave;

        emit SweepRequested(ref, t.chainId, wallet, t.token, toSave);
        _callback(
            t.chainId,
            vault,
            SWEEP_GAS,
            abi.encodeCall(ISavingsVault.sweep, (address(0), t.token, wallet, toSave, ref))
        );
    }

    /// @dev Rule 3: scheduled statements.
    function _onCronTick() internal {
        if (block.timestamp < nextStatementAt || statementRecipient == address(0)) return;
        nextStatementAt = block.timestamp + statementInterval;
        _postStatement();
    }

    function _postStatement() internal {
        if (statementRecipient == address(0)) revert StatementTargetMissing();
        StatementLine[] memory lines = previewStatement();
        uint256 seq = ++statementSeq;
        emit StatementRequested(seq, block.timestamp, lines.length);
        _callback(
            statementChainId,
            statementRecipient,
            STATEMENT_GAS,
            abi.encodeCall(IStatement.record, (address(0), seq, block.timestamp, lines))
        );
    }

    // ================================================================================================
    // Plumbing
    // ================================================================================================

    function _callback(uint256 chainId, address recipient, uint64 gasLimit, bytes memory payload) internal {
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: chainId, recipient: recipient, gasLimit: gasLimit, payload: payload
            })
        );
    }

    /// @dev Outgoing (wallet in topic1) and incoming (wallet in topic2) transfers of one token.
    function _subscribePair(uint256 chainId, address token, address wallet) internal {
        uint256 w = uint256(uint160(wallet));
        SYSTEM.subscribe(chainId, token, TRANSFER_TOPIC0, w, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(chainId, token, TRANSFER_TOPIC0, REACTIVE_IGNORE, w, REACTIVE_IGNORE);
    }

    /// @dev Must mirror `_subscribePair` exactly: `unsubscribe` only removes an identical criteria set.
    function _unsubscribePair(uint256 chainId, address token, address wallet) internal {
        uint256 w = uint256(uint160(wallet));
        SYSTEM.unsubscribe(chainId, token, TRANSFER_TOPIC0, w, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.unsubscribe(chainId, token, TRANSFER_TOPIC0, REACTIVE_IGNORE, w, REACTIVE_IGNORE);
    }

    function _removeVaultChain(uint256 chainId) internal {
        uint256 last = _vaultChains.length - 1;
        for (uint256 i = 0; i <= last; ++i) {
            if (_vaultChains[i] == chainId) {
                _vaultChains[i] = _vaultChains[last];
                _vaultChains.pop();
                return;
            }
        }
    }

    function _today() internal view returns (uint256) {
        return block.timestamp / 1 days;
    }
}
