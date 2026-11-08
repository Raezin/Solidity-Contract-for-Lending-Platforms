// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./ZUSD.sol";
import "./WRBTC.sol";
import "./interfaces/IStabilityPool.sol";

/// @notice Delivery-ready Stability Pool Mock
contract StabilityPoolMock is ReentrancyGuard, Ownable, IStabilityPool {
    using SafeERC20 for ZUSD;
    using SafeERC20 for WRBTC;

    ZUSD public immutable zusd;
    WRBTC public immutable wrbtc;
    address public borrowerOps; // Trusted BorrowerOperationsMock

    uint256 public totalDeposits;
    mapping(address => uint256) public deposits;

    uint256 public totalCollateralFromLiquidations;

    // ------------------------- Events -------------------------
    event Deposited(address indexed user, uint256 amountZUSD);
    event WithdrawnZUSD(address indexed user, uint256 amountZUSD);
    event CollateralReceivedFromLiquidation(uint256 amountWRBTC, uint256 debtZUSD);
    event WithdrawCollateral(address indexed user, uint256 collateralWRBTC);
    event BorrowerOpsSet(address indexed borrowerOps);
    event RescuedZUSD(address indexed to, uint256 amount);
    event RescuedWRBTC(address indexed to, uint256 amount);

    // ------------------------- Modifiers -------------------------
    modifier onlyBorrowerOps() {
        require(msg.sender == borrowerOps, "SP: only borrowerOps");
        _;
    }

    // ------------------------- Constructor -------------------------
    constructor(address _zusd, address _wrbtc) {
        require(_zusd != address(0) && _wrbtc != address(0), "SP: zero address");
        zusd = ZUSD(_zusd);
        wrbtc = WRBTC(_wrbtc);
    }

    // ------------------------- Admin -------------------------
    function setBorrowerOps(address _borrowerOps) external onlyOwner {
        require(_borrowerOps != address(0), "SP: zero borrowerOps");
        borrowerOps = _borrowerOps;
        emit BorrowerOpsSet(_borrowerOps);
    }

    function rescueZUSD(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "SP: zero address");
        zusd.safeTransfer(to, amount);
        emit RescuedZUSD(to, amount);
    }

    function rescueWRBTC(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "SP: zero address");
        wrbtc.safeTransfer(to, amount);
        emit RescuedWRBTC(to, amount);
    }

    // ------------------------- User Functions -------------------------
    function deposit(uint256 amount) external nonReentrant {
        require(amount > 0, "SP: zero deposit");
        zusd.safeTransferFrom(msg.sender, address(this), amount);
        deposits[msg.sender] += amount;
        totalDeposits += amount;
        emit Deposited(msg.sender, amount);
    }

    function withdrawDeposit(uint256 amount) external nonReentrant {
        require(amount > 0 && deposits[msg.sender] >= amount, "SP: invalid withdraw");
        deposits[msg.sender] -= amount;
        totalDeposits -= amount;
        zusd.safeTransfer(msg.sender, amount);
        emit WithdrawnZUSD(msg.sender, amount);
    }

    /// Called by BorrowerOps on liquidation
    function receiveCollateralFromLiquidation(uint256 collateralWRBTC, uint256 debtZUSD) external override nonReentrant onlyBorrowerOps {
        require(collateralWRBTC > 0, "SP: zero collateral");
        totalCollateralFromLiquidations += collateralWRBTC;
        emit CollateralReceivedFromLiquidation(collateralWRBTC, debtZUSD);
    }

    /// Users withdraw proportional WRBTC based on their ZUSD deposits
    function withdrawCollateral() external nonReentrant {
        uint256 userDeposit = deposits[msg.sender];
        require(userDeposit > 0, "SP: no deposit");
        require(totalDeposits > 0 && totalCollateralFromLiquidations > 0, "SP: nothing to withdraw");

        uint256 collateralShare = (totalCollateralFromLiquidations * userDeposit) / totalDeposits;
        require(collateralShare > 0, "SP: zero share");

        deposits[msg.sender] = 0;
        totalDeposits -= userDeposit;
        totalCollateralFromLiquidations -= collateralShare;

        wrbtc.safeTransfer(msg.sender, collateralShare);
        emit WithdrawCollateral(msg.sender, collateralShare);
    }

    // ---------- View Helpers ----------
    function getDepositorShare(address user) external view returns (uint256) {
        if (totalDeposits == 0 || totalCollateralFromLiquidations == 0) return 0;
        return (totalCollateralFromLiquidations * deposits[user]) / totalDeposits;
    }
}
