// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ZUSD is ERC20, ERC20Burnable, Ownable {
    constructor() ERC20("ZUSD Stablecoin", "ZUSD") {}

    /// @notice Mint tokens to an address
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
