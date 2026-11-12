// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice Stand-in for Reactive Network's system contract (0x8888...8888), etched there in tests.
/// @dev Mirrors the parts of the real interface Ledgerline uses: subscriptions, callback requests and
///      the debt/payment bookkeeping. Subscriptions are tracked as a set so tests can assert on them.
contract MockSystemContract {
    struct Request {
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
        address requester;
    }

    event CallbackRequest(
        uint256 indexed chainId,
        address indexed sender,
        address indexed recipient,
        uint8 version,
        bytes configuration
    );

    mapping(bytes32 => bool) public isSubscribed;
    uint256 public activeSubscriptions;
    uint256 public subscribeCalls;
    uint256 public unsubscribeCalls;

    Request[] internal _requests;

    /// @notice When true, callback requests are only emitted (like the real contract), not stored.
    ///         Gas measurements use it so the mock's bookkeeping doesn't inflate them.
    /// @dev Defaults to false on purpose: the mock is etched, so constructor/initializer code never runs.
    bool public emitOnly;
    mapping(address => uint256) public debt;

    function subscribe(uint256 chainId, address contract_, uint256 t0, uint256 t1, uint256 t2, uint256 t3)
        external
    {
        ++subscribeCalls;
        bytes32 key = subscriptionKey(msg.sender, chainId, contract_, t0, t1, t2, t3);
        if (!isSubscribed[key]) {
            isSubscribed[key] = true;
            ++activeSubscriptions;
        }
    }

    function unsubscribe(uint256 chainId, address contract_, uint256 t0, uint256 t1, uint256 t2, uint256 t3)
        external
    {
        ++unsubscribeCalls;
        bytes32 key = subscriptionKey(msg.sender, chainId, contract_, t0, t1, t2, t3);
        if (isSubscribed[key]) {
            isSubscribed[key] = false;
            --activeSubscriptions;
        }
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_) external {
        if (config_.gasLimit < 100_000) revert("gas limit below network minimum");
        if (debt[msg.sender] > 0) revert("in debt");
        if (!emitOnly) {
            _requests.push(
                Request(config_.chainId, config_.recipient, config_.gasLimit, config_.payload, msg.sender)
            );
        }
        emit CallbackRequest(config_.chainId, msg.sender, config_.recipient, 0, abi.encode(config_));
    }

    // --- payment side -------------------------------------------------------------------------------

    function setDebt(address contract_, uint256 amount) external {
        debt[contract_] = amount;
    }

    receive() external payable {
        // A payment from a contract settles its debt, like the real system contract.
        uint256 d = debt[msg.sender];
        debt[msg.sender] = msg.value >= d ? 0 : d - msg.value;
    }

    // --- test helpers -------------------------------------------------------------------------------

    function subscriptionKey(
        address subscriber,
        uint256 chainId,
        address contract_,
        uint256 t0,
        uint256 t1,
        uint256 t2,
        uint256 t3
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(subscriber, chainId, contract_, t0, t1, t2, t3));
    }

    function requestCount() external view returns (uint256) {
        return _requests.length;
    }

    function requestAt(uint256 i) external view returns (Request memory) {
        return _requests[i];
    }

    function setEmitOnly(bool on) external {
        emitOnly = on;
    }

    function clearRequests() external {
        delete _requests;
    }
}
