// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IBorrowerOperations {
    function openTrove(uint256 maxFeeBps, uint256 zusdAmount) external payable;
    function addColl() external payable;
    function withdrawZUSD(uint256 maxFeeBps, uint256 zusdAmount) external;
    function repayZUSD(uint256 amount) external;
    function withdrawColl(uint256 amount) external;
    function closeTrove() external;
}
