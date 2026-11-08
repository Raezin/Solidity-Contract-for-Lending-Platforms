// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IOracleMedianizer {
    function getMedianPrice() external view returns (uint256);
}
