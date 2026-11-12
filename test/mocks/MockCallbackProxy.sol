// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice Stand-in for a destination chain's callback proxy.
/// @dev Like the real proxy it overwrites the payload's first argument with the requesting reactive
///      contract's address before calling the recipient, and it can bill the recipient via `pay()`.
contract MockCallbackProxy {
    mapping(address => uint256) public debt;

    event Delivered(address indexed recipient, bool success);

    /// @notice Deliver `payload` to `recipient` as if `rvm` requested it.
    function deliver(address recipient, bytes memory payload, address rvm)
        public
        returns (bool success, bytes memory ret)
    {
        require(payload.length >= 36, "payload has no address slot");
        assembly ("memory-safe") {
            mstore(add(payload, 36), rvm) // bytes [4, 36): first ABI word after the selector
        }
        (success, ret) = recipient.call(payload);
        emit Delivered(recipient, success);
    }

    function setDebt(address contract_, uint256 amount) external {
        debt[contract_] = amount;
    }

    /// @notice Ask a recipient to pay what it owes, like `_charge()` does on the real proxy.
    function charge(address contract_) external returns (bool success) {
        (success,) = contract_.call(abi.encodeWithSignature("pay(uint256)", debt[contract_]));
    }

    receive() external payable {
        uint256 d = debt[msg.sender];
        debt[msg.sender] = msg.value >= d ? 0 : d - msg.value;
    }
}
