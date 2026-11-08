// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IStabilityPool {
    function receiveCollateralFromLiquidation(uint256 collateralWRBTC, uint256 debtZUSD) external;
}
