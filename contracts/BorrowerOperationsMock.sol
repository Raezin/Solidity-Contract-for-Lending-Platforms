// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./ZUSD.sol";
import "./WRBTC.sol";
import "./interfaces/IStabilityPool.sol";
import "./interfaces/IUserProxy.sol";
import "./interfaces/IOracleMedianizer.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract BorrowerOperationsMock is Ownable, ReentrancyGuard {
    using SafeERC20 for ZUSD;
    using SafeERC20 for WRBTC;

    ZUSD public immutable zusd;
    WRBTC public immutable wrbtc;
    IOracleMedianizer public oracle;

    uint256 public baseRateBps;
    uint256 public constant EXTRA_FIXED_BPS = 500; // +5% fixed
    uint256 public reserveAmount;                  // upfront reserve (e.g., 5 ZUSD)

    struct Trove {
        uint256 collateralWRBTC; // in wei (1e18)
        uint256 debtZUSD;        // in ZUSD units (respect decimals of ZUSD)
    }
    mapping(address => Trove) public Troves;

    uint256 public minCollateralRatioBps = 11000; // 110%
    uint256 public goodCollateralRatioBps = 20000; // 200%

    address public stabilityPool;

    // ------------------------- Events -------------------------
    event TroveOpened(address indexed user, uint256 collateralWRBTC, uint256 debtZUSD);
    event CollateralAdded(address indexed user, uint256 amountWRBTC);
    event CollateralWithdrawn(address indexed user, uint256 amountWRBTC);
    event ZUSDWithdrawn(address indexed user, uint256 amountZUSD); // amount requested (pre-fee)
    event ZUSDRepaid(address indexed user, uint256 amountZUSD);
    event TroveClosed(address indexed user);
    event TroveLiquidated(address indexed user, uint256 collateralWRBTC, uint256 debtZUSD);
    event BaseRateUpdated(uint256 newBaseRateBps);
    event ReserveUpdated(uint256 newReserve);

    constructor(
        address _zusd,
        address _wrbtc,
        address _oracle,
        uint256 _baseRateBps
    ) {
        require(_zusd != address(0) && _wrbtc != address(0) && _oracle != address(0), "BOM: invalid addr");
        zusd = ZUSD(_zusd);
        wrbtc = WRBTC(_wrbtc);
        oracle = IOracleMedianizer(_oracle);
        baseRateBps = _baseRateBps;
        // Default reserve lowered to 5 ZUSD for test convenience
        reserveAmount = 5 * (10 ** zusd.decimals()); // default 5 ZUSD reserve
    }

    // ------------------------- Internal -------------------------
    /// Resolve the **real user** even when call comes from a UserProxy
    function _detectUser() internal view returns (address) {
        (bool ok, bytes memory ret) = msg.sender.staticcall(
            abi.encodeWithSelector(IUserProxy.owner.selector)
        );
        if (ok && ret.length >= 32) {
            address ownerAddr = abi.decode(ret, (address));
            if (ownerAddr != address(0)) return ownerAddr;
        }
        return msg.sender;
    }

    /// Fee math used by UI and withdraw path
    function calculateFee(uint256 requestedAmount)
        public
        view
        returns (
            uint256 fee,
            uint256 netAmount,
            uint256 reserve,
            uint256 feeBpsApplied
        )
    {
        feeBpsApplied = baseRateBps + EXTRA_FIXED_BPS;
        reserve = reserveAmount;

        if (requestedAmount <= reserve) {
            // Nothing goes out; entirely “covered” by reserve
            return (0, 0, reserve, feeBpsApplied);
        }

        uint256 taxable = requestedAmount - reserve;
        fee = (taxable * feeBpsApplied) / 10000;
        netAmount = requestedAmount - reserve - fee;
    }

    function _isCollateralSufficient(uint256 collateralWRBTC, uint256 debtZUSD) internal view returns (bool) {
        if (debtZUSD == 0) return true;
        uint256 price = oracle.getMedianPrice();
        require(price > 0, "BOM: bad oracle price");

        // collateral in WRBTC wei; price in 1e18 => value(18) = collateral * price / 1e18
        uint256 collateralValue18 = (collateralWRBTC * price) / 1e18;
        uint256 ratioBps = (collateralValue18 * 10000) / debtZUSD;
        return ratioBps >= minCollateralRatioBps;
    }

    // ------------------------- Trove Operations -------------------------

    /// deposit + optional borrow
    function openTrove(uint256 maxFeeBps, uint256 zusdAmount)
        external
        payable
        nonReentrant
    {
        address user = _detectUser();
        Trove storage t = Troves[user];

        require(t.debtZUSD == 0, "BOM: trove exists");
        require(msg.value > 0 || zusdAmount == 0, "BOM: need collateral or zero borrow");

        // "Wrap" RBTC -> WRBTC (mocked by minting WRBTC to this contract)
        if (msg.value > 0) {
            wrbtc.mint(address(this), msg.value);
            t.collateralWRBTC += msg.value;
            emit CollateralAdded(user, msg.value);
        }

        // Borrow ZUSD directly to the **user**
        if (zusdAmount > 0) {
            (uint256 fee,, , uint256 feeBpsApplied) = calculateFee(zusdAmount);
            require(feeBpsApplied <= maxFeeBps || maxFeeBps == 0, "BOM: fee exceeds max");

            (, uint256 net,,) = calculateFee(zusdAmount);
            require(net > 0, "BOM: net=0");

            // Mint net to user (reserve & fee are implicit—nothing minted)
            zusd.mint(user, net);
            t.debtZUSD += zusdAmount; // debt is the requested amount (pre-fee), same as Sovryn accounting
            emit ZUSDWithdrawn(user, zusdAmount);
        }

        require(_isCollateralSufficient(t.collateralWRBTC, t.debtZUSD), "BOM: insufficient collateral");
        emit TroveOpened(user, t.collateralWRBTC, t.debtZUSD);
    }

    /// add collateral only
    function addColl()
        external
        payable
        nonReentrant
    {
        address user = _detectUser();
        require(msg.value > 0, "BOM: zero collateral");
        Trove storage t = Troves[user];

        wrbtc.mint(address(this), msg.value);
        t.collateralWRBTC += msg.value;
        emit CollateralAdded(user, msg.value);
    }

    /// borrow additional ZUSD
    function withdrawZUSD(uint256 maxFeeBps, uint256 zusdAmount)
        external
        nonReentrant
    {
        address user = _detectUser();
        require(zusdAmount > 0, "BOM: zero withdraw");
        Trove storage t = Troves[user];

        (,, , uint256 feeBpsApplied) = calculateFee(zusdAmount);
        require(feeBpsApplied <= maxFeeBps || maxFeeBps == 0, "BOM: fee exceeds max");

        (, uint256 net,,) = calculateFee(zusdAmount);
        require(net > 0, "BOM: net=0");

        zusd.mint(user, net);
        t.debtZUSD += zusdAmount;

        require(_isCollateralSufficient(t.collateralWRBTC, t.debtZUSD), "BOM: insufficient after withdraw");
        emit ZUSDWithdrawn(user, zusdAmount);
    }

    /// repay ZUSD (Adapter transfers ZUSD here first, then this burns)
    function repayZUSD(uint256 amount)
        external
        nonReentrant
    {
        address user = _detectUser();
        Trove storage t = Troves[user];
        require(amount > 0 && t.debtZUSD >= amount, "BOM: invalid repay");

        // We expect this contract to hold the tokens (Adapter already safeTransferFrom(user, this, amount))
        zusd.burn(amount);
        t.debtZUSD -= amount;
        emit ZUSDRepaid(user, amount);
    }

    /// withdraw collateral (must remain healthy if debt > 0)
    function withdrawColl(uint256 amount)
        external
        nonReentrant
    {
        address user = _detectUser();
        Trove storage t = Troves[user];
        require(amount > 0 && t.collateralWRBTC >= amount, "BOM: invalid withdraw");

        t.collateralWRBTC -= amount;
        wrbtc.safeTransfer(user, amount);

        if (t.debtZUSD > 0) {
            require(_isCollateralSufficient(t.collateralWRBTC, t.debtZUSD), "BOM: undercollateralized");
        }
        emit CollateralWithdrawn(user, amount);
    }

    /// close trove (requires zero debt)
    function closeTrove()
        external
        nonReentrant
    {
        address user = _detectUser();
        Trove storage t = Troves[user];
        require(t.debtZUSD == 0, "BOM: outstanding debt");

        uint256 coll = t.collateralWRBTC;
        t.collateralWRBTC = 0;

        if (coll > 0) wrbtc.safeTransfer(user, coll);
        emit TroveClosed(user);
    }

    /// liquidation entry (owner or stability pool can trigger)
    function liquidateTrove(address user)
        external
        nonReentrant
    {
        require(msg.sender == owner() || msg.sender == stabilityPool, "BOM: unauthorized liquidation");
        Trove storage t = Troves[user];
        require(t.debtZUSD > 0 && !_isCollateralSufficient(t.collateralWRBTC, t.debtZUSD), "BOM: trove healthy");

        uint256 coll = t.collateralWRBTC;
        uint256 debt = t.debtZUSD;
        t.collateralWRBTC = 0;
        t.debtZUSD = 0;

        require(stabilityPool != address(0), "BOM: stability pool not set");
        wrbtc.safeTransfer(stabilityPool, coll);
        IStabilityPool(stabilityPool).receiveCollateralFromLiquidation(coll, debt);
        emit TroveLiquidated(user, coll, debt);
    }

    // ------------------------- Views -------------------------

    /// returns the trove data stored in BorrowerOperationsMock (collateral in WRBTC wei, debt in ZUSD)
    function getTrove(address user) external view returns (uint256 collateralWRBTC, uint256 debtZUSD) {
        Trove storage t = Troves[user];
        return (t.collateralWRBTC, t.debtZUSD);
    }

    /// returns collateral, debt, collateral value (1e18), ratio bps, health(0=Good,1=Watch,2=AddBTC)
    function getPosition(address user) external view returns (
        uint256 collateralWRBTC,
        uint256 debtZUSD,
        uint256 collateralValue18,
        uint256 ratioBps,
        uint8 health
    ) {
        Trove storage t = Troves[user];
        collateralWRBTC = t.collateralWRBTC;
        debtZUSD = t.debtZUSD;

        if (debtZUSD == 0) {
            // no debt -> infinite ratio, healthy
            uint256 price0 = oracle.getMedianPrice();
            collateralValue18 = (collateralWRBTC * price0) / 1e18;
            ratioBps = type(uint256).max;
            health = 0;
            return (collateralWRBTC, debtZUSD, collateralValue18, ratioBps, health);
        }

        uint256 price = oracle.getMedianPrice();
        require(price > 0, "BOM: bad oracle price");

        collateralValue18 = (collateralWRBTC * price) / 1e18;
        ratioBps = (collateralValue18 * 10000) / debtZUSD;

        if (ratioBps >= goodCollateralRatioBps) {
            health = 0;
        } else if (ratioBps >= minCollateralRatioBps) {
            health = 1;
        } else {
            health = 2;
        }

        return (collateralWRBTC, debtZUSD, collateralValue18, ratioBps, health);
    }

    /// returns current min and good collateral ratio thresholds (bps)
    function getCollateralRatios() external view returns (uint256 minBps, uint256 goodBps) {
        return (minCollateralRatioBps, goodCollateralRatioBps);
    }

    // ------------------------- Admin -------------------------
    function setBaseRateBps(uint256 bps) external onlyOwner {
        baseRateBps = bps;
        emit BaseRateUpdated(bps);
    }

    function setReserveAmount(uint256 amount) external onlyOwner {
        reserveAmount = amount;
        emit ReserveUpdated(amount);
    }

    function setMinCollateralRatioBps(uint256 bps) external onlyOwner { minCollateralRatioBps = bps; }
    function setGoodCollateralRatioBps(uint256 bps) external onlyOwner { goodCollateralRatioBps = bps; }
    function setOracle(address _oracle) external onlyOwner { oracle = IOracleMedianizer(_oracle); }
    function setStabilityPool(address _stabilityPool) external onlyOwner { stabilityPool = _stabilityPool; }
}
