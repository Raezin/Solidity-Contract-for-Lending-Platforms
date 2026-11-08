// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Mock ERC20 for Wrapped RBTC
contract WRBTC is ERC20, Ownable {
    constructor() ERC20("Wrapped RBTC", "WRBTC") {}

    /// @notice Mint tokens to an address
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Burn tokens from caller
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
