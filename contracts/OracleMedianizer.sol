// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";

interface IPriceFeed { function getPrice() external view returns (uint256); }

contract OracleMedianizer is Ownable {
    IPriceFeed public feed1;
    IPriceFeed public feed2;
    uint256 public deviationThreshold = 2 * 1e16; // 2% in 18 decimals

    event FeedsUpdated(address feed1, address feed2);
    event DeviationThresholdUpdated(uint256 newThreshold);

    constructor(address _feed1, address _feed2) {
        feed1 = IPriceFeed(_feed1);
        feed2 = IPriceFeed(_feed2);
    }

    function setFeeds(address _feed1, address _feed2) external onlyOwner {
        feed1 = IPriceFeed(_feed1);
        feed2 = IPriceFeed(_feed2);
        emit FeedsUpdated(_feed1, _feed2);
    }

    function setDeviationThreshold(uint256 _threshold) external onlyOwner {
        deviationThreshold = _threshold;
        emit DeviationThresholdUpdated(_threshold);
    }

    function isDeviated() public view returns (bool) {
        uint256 price1 = feed1.getPrice();
        uint256 price2 = feed2.getPrice();
        if (price1 == 0 || price2 == 0) return true;
        uint256 diff = price1 > price2 ? price1 - price2 : price2 - price1;
        uint256 deviation = (diff * 1e18) / ((price1 + price2) / 2);
        return deviation > deviationThreshold;
    }

    function getMedianPrice() public view returns (uint256) {
        uint256 price1 = feed1.getPrice();
        uint256 price2 = feed2.getPrice();
        return (price1 + price2) / 2;
    }
}
