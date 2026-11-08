// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./interfaces/IBorrowerOperations.sol";

/// @notice Minimal per-user proxy:
/// - Stores the *real user* as `owner`
/// - Allows an `authorized` Adapter to perform BorrowerOperations on behalf of the owner
/// - Exposes wrappers that call BorrowerOperations with msg.value where needed
/// - Supports safe rotation of `authorized` and `borrowerOps` by owner or current authorized
contract UserProxy {
    address public owner;                  // Real user (EOA or smart wallet)
    address public authorized;             // Adapter allowed to call on behalf of owner
    IBorrowerOperations public borrowerOps;

    bool private initialized;

    event Initialized(address indexed owner, address indexed authorized, address borrowerOps);
    event AuthorizedUpdated(address indexed oldAuthorized, address indexed newAuthorized);
    event BorrowerOpsUpdated(address indexed oldBorrowerOps, address indexed newBorrowerOps);
    event Executed(address indexed caller, address indexed target, bytes data, uint256 value);

    modifier onlyAuthorizedOrOwner() {
        require(msg.sender == owner || msg.sender == authorized, "UserProxy: not allowed");
        _;
    }

    /// @notice One-time setup called by Adapter at first use.
    function initialize(
        address _owner,
        address _borrowerOps,
        address _authorized
    ) external {
        require(!initialized, "UserProxy: already initialized");
        require(_owner != address(0), "UserProxy: zero owner");
        require(_borrowerOps != address(0), "UserProxy: zero borrowerOps");
        require(_authorized != address(0), "UserProxy: zero authorized");

        owner = _owner;
        borrowerOps = IBorrowerOperations(_borrowerOps);
        authorized = _authorized;
        initialized = true;

        emit Initialized(_owner, _authorized, _borrowerOps);
    }

    // ---------------- Rotation hooks (for adapter/BO upgrades) ----------------

    /// @notice Rotate the authorized Adapter (e.g., mock → mainnet).
    /// @dev Callable by current authorized Adapter or the owner.
    function setAuthorized(address _newAuthorized) external onlyAuthorizedOrOwner {
        require(_newAuthorized != address(0), "UserProxy: zero authorized");
        emit AuthorizedUpdated(authorized, _newAuthorized);
        authorized = _newAuthorized;
    }

    /// @notice Point to a new BorrowerOperations (e.g., mock → mainnet).
    /// @dev Callable by current authorized Adapter or the owner.
    function setBorrowerOps(address _newBorrowerOps) external onlyAuthorizedOrOwner {
        require(_newBorrowerOps != address(0), "UserProxy: zero borrowerOps");
        emit BorrowerOpsUpdated(address(borrowerOps), _newBorrowerOps);
        borrowerOps = IBorrowerOperations(_newBorrowerOps);
    }

    // ---------------- Generic executor (optional use) ----------------

    /// @notice Low-level arbitrary call if needed; bubbles up reverts.
    /// @dev Restricted to owner or authorized Adapter.
    function execute(address target, bytes calldata data)
        external
        payable
        onlyAuthorizedOrOwner
        returns (bytes memory)
    {
        (bool ok, bytes memory ret) = target.call{value: msg.value}(data);
        if (!ok) {
            // bubble revert reason
            if (ret.length > 0) {
                assembly {
                    let size := mload(ret)
                    revert(add(ret, 32), size)
                }
            } else {
                revert("UserProxy: call failed");
            }
        }
        emit Executed(msg.sender, target, data, msg.value);
        return ret;
    }

    // ---------------- Typed BorrowerOperations wrappers ----------------

    function openTrove(uint256 _maxFeeBps, uint256 _ZUSDAmount)
        external
        payable
        onlyAuthorizedOrOwner
    {
        borrowerOps.openTrove{value: msg.value}(_maxFeeBps, _ZUSDAmount);
    }

    function addColl()
        external
        payable
        onlyAuthorizedOrOwner
    {
        borrowerOps.addColl{value: msg.value}();
    }

    function withdrawZUSD(uint256 _maxFeeBps, uint256 _ZUSDAmount)
        external
        onlyAuthorizedOrOwner
    {
        borrowerOps.withdrawZUSD(_maxFeeBps, _ZUSDAmount);
    }

    function repayZUSD(uint256 _ZUSDAmount)
        external
        onlyAuthorizedOrOwner
    {
        borrowerOps.repayZUSD(_ZUSDAmount);
    }

    function withdrawColl(uint256 _amount)
        external
        onlyAuthorizedOrOwner
    {
        borrowerOps.withdrawColl(_amount);
    }

    function closeTrove()
        external
        onlyAuthorizedOrOwner
    {
        borrowerOps.closeTrove();
    }

    receive() external payable {}
}
