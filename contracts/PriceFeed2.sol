// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import "@openzeppelin/contracts/access/Ownable.sol";

contract PriceFeed2 is Ownable {
    uint256 private price;
    event PriceUpdated(uint256 newPrice);
    function setPrice(uint256 _price) external onlyOwner { price = _price; emit PriceUpdated(_price); }
    function getPrice() external view returns (uint256) { return price; }
}
