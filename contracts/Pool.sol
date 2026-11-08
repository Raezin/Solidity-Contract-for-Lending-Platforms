// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IOracleMedianizer {
    function getMedianPrice() external view returns (uint256);
    function isDeviated() external view returns (bool);
}

interface ISovrynAdapterWithProxies {
    function openTroveFor(address user, uint256 maxFeeBps, uint256 zusdAmount) external payable;
    function depositCollateralFor(address user) external payable;
    function withdrawZUSDFor(address user, uint256 maxFeeBps, uint256 zusdAmount) external;
    function repayZUSDFor(address user, uint256 amount) external;
    function withdrawCollFor(address user, uint256 amount) external;
    function closeTroveFor(address user) external;
    function setMinCollateralRatioBps(uint256 bps) external;
    function setBaseRateBps(uint256 bps) external;
}

contract Pool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    ISovrynAdapterWithProxies public adapter;
    IOracleMedianizer public oracle;
    IERC20 public debtToken;
    uint8 public debtTokenDecimals;

    bool public paused;
    address public admin;
    uint256 public perWalletCap;
    uint256 public protocolCap;
    uint256 public totalBorrowed;

    struct Position {
        uint256 collateral; // RBTC in wei
        uint256 borrowed;   // ZUSD (debt principal tracked for caps/health)
    }
    mapping(address => Position) public positions;

    // ---------- Events ----------
    event LoanOpened(address indexed user, uint256 collateralAdded, uint256 borrowed);
    event LoanWithdrawn(address indexed user, uint256 borrowed);
    event Repaid(address indexed user, uint256 amount);
    event CollateralAdded(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event PositionClosed(address indexed user, uint256 collateralReturned);
    event Paused();
    event Unpaused();
    event CapsSet(uint256 perWalletCap, uint256 protocolCap);

    // ---------- Modifiers ----------
    modifier onlyAdmin() { require(msg.sender == admin, "Pool: not admin"); _; }
    modifier notPaused() { require(!paused, "Pool: paused"); _; }

constructor(
    address _adapter,
    address _oracle,
    address _debtToken,
    uint256 _perWalletCap,
    uint256 _protocolCap,
    address _owner // NEW PARAMETER
) {
    require(_adapter != address(0) && _oracle != address(0) && _debtToken != address(0), "Pool: zero address");
    
    adapter = ISovrynAdapterWithProxies(_adapter);
    oracle = IOracleMedianizer(_oracle);
    debtToken = IERC20(_debtToken);

    try IERC20Metadata(_debtToken).decimals() returns (uint8 d) {
        debtTokenDecimals = d;
    } catch {
        debtTokenDecimals = 18;
    }

    perWalletCap = _perWalletCap;
    protocolCap = _protocolCap;
    paused = false;

    // explicitly set owner to the deployer or a provided address
    _transferOwnership(_owner);
    admin = _owner;
}


    // ---------- Admin ----------
    function setAdmin(address _admin) external onlyOwner { admin = _admin; }

    function setCaps(uint256 _perWalletCap, uint256 _protocolCap) external onlyAdmin {
        perWalletCap = _perWalletCap;
        protocolCap = _protocolCap;
        emit CapsSet(_perWalletCap, _protocolCap);
    }

    function setCollateralRatio(uint256 bps) external onlyAdmin {
        adapter.setMinCollateralRatioBps(bps);
    }

    function setInterestRate(uint256 bps) external onlyAdmin {
        adapter.setBaseRateBps(bps);
    }

    function pause() external onlyAdmin { paused = true; emit Paused(); }
    function unpause() external onlyAdmin { paused = false; emit Unpaused(); }

    function setAdapter(address _adapter) external onlyAdmin {
        require(_adapter != address(0), "Pool: zero adapter");
        adapter = ISovrynAdapterWithProxies(_adapter);
    }

    function setOracle(address _oracle) external onlyAdmin {
        require(_oracle != address(0), "Pool: zero oracle");
        oracle = IOracleMedianizer(_oracle);
    }

    // ---------- User actions ----------
    function openTrove(uint256 maxFeeBps, uint256 zusdAmount) external payable nonReentrant notPaused {
        _checkOracle();

        Position storage p = positions[msg.sender];
        require(p.borrowed + zusdAmount <= perWalletCap, "Pool: per-wallet cap exceeded");
        require(totalBorrowed + zusdAmount <= protocolCap, "Pool: protocol cap exceeded");

        // Forward collateral + borrow to Adapter (RBTC value goes through; BorrowerOps handles WRBTC wrap)
        adapter.openTroveFor{value: msg.value}(msg.sender, maxFeeBps, zusdAmount);

        // Update local accounting
        if (msg.value > 0) {
            p.collateral += msg.value;
            emit CollateralAdded(msg.sender, msg.value);
        }
        if (zusdAmount > 0) {
            p.borrowed += zusdAmount;
            totalBorrowed += zusdAmount;
        }
        emit LoanOpened(msg.sender, msg.value, zusdAmount);
    }

    function addCollateral() external payable nonReentrant notPaused {
        require(msg.value > 0, "Pool: zero RBTC");
        Position storage p = positions[msg.sender];

        adapter.depositCollateralFor{value: msg.value}(msg.sender);

        p.collateral += msg.value;
        emit CollateralAdded(msg.sender, msg.value);
    }

    function withdrawZUSD(uint256 maxFeeBps, uint256 zusdAmount) external nonReentrant notPaused {
        require(zusdAmount > 0, "Pool: zero borrow");
        _checkOracle(); // block new borrowing when oracle is deviated

        Position storage p = positions[msg.sender];
        require(p.borrowed + zusdAmount <= perWalletCap, "Pool: per-wallet cap exceeded");
        require(totalBorrowed + zusdAmount <= protocolCap, "Pool: protocol cap exceeded");

        adapter.withdrawZUSDFor(msg.sender, maxFeeBps, zusdAmount);

        // update accounting
        p.borrowed += zusdAmount;
        totalBorrowed += zusdAmount;

        emit LoanWithdrawn(msg.sender, zusdAmount);
    }

    function repay(uint256 amount) external nonReentrant {
        require(amount > 0, "Pool: zero repay");
        Position storage p = positions[msg.sender];
        require(p.borrowed >= amount, "Pool: repay too high");

        adapter.repayZUSDFor(msg.sender, amount);

        p.borrowed -= amount;
        totalBorrowed -= amount;
        emit Repaid(msg.sender, amount);
    }

    function withdrawCollateral(uint256 amount) external nonReentrant {
        require(amount > 0, "Pool: zero withdraw");
        Position storage p = positions[msg.sender];
        require(p.collateral >= amount, "Pool: not enough collateral");

        adapter.withdrawCollFor(msg.sender, amount);

        p.collateral -= amount;
        emit CollateralWithdrawn(msg.sender, amount);
    }

    function closePosition() external nonReentrant {
        Position storage p = positions[msg.sender];

        if (p.borrowed > 0) {
            adapter.repayZUSDFor(msg.sender, p.borrowed);
            totalBorrowed -= p.borrowed;
            p.borrowed = 0;
            emit Repaid(msg.sender, 0);
        }

        if (p.collateral > 0) {
            adapter.withdrawCollFor(msg.sender, p.collateral);
            uint256 col = p.collateral;
            p.collateral = 0;
            emit PositionClosed(msg.sender, col);
        }
    }

    // ---------- Views ----------
    function getCollateralRatio(address user) public view returns (uint256) {
        Position storage p = positions[user];
        if (p.borrowed == 0) return type(uint256).max;

        uint256 price = oracle.getMedianPrice();
        require(price > 0, "Pool: invalid oracle price");

        // RBTC collateral (wei) * price (1e18) / 1e18 → 18 decimals value
        uint256 collateralValue18 = (p.collateral * price) / 1e18;

        // align to debt token decimals for a clean ratio
        uint256 adjustedCollateral = debtTokenDecimals >= 18
            ? collateralValue18 * (10 ** (debtTokenDecimals - 18))
            : collateralValue18 / (10 ** (18 - debtTokenDecimals));

        return (adjustedCollateral * 10000) / p.borrowed; // bps
    }

    /// 0 = Good (>=200%), 1 = Watch (>=110%), 2 = AddBTC (<110%)
    function getHealth(address user) external view returns (uint8) {
        uint256 ratio = getCollateralRatio(user);
        if (ratio >= 20000) return 0;
        if (ratio >= 11000) return 1;
        return 2;
    }

    /// Returns per-wallet and protocol caps
    function getCaps() external view returns (uint256 _perWalletCap, uint256 _protocolCap) {
        return (perWalletCap, protocolCap);
    }

    /// Returns position summary from Pool's accounting:
    /// (collateralRBTCWei, borrowed (ZUSD pre-fee), collateralValue18, ratioBps, health)
    function getPosition(address user) external view returns (
        uint256 collateralRBTCWei,
        uint256 borrowed,
        uint256 collateralValue18,
        uint256 ratioBps,
        uint8 health
    ) {
        Position storage p = positions[user];
        collateralRBTCWei = p.collateral;
        borrowed = p.borrowed;

        if (borrowed == 0) {
            uint256 price0 = oracle.getMedianPrice();
            collateralValue18 = (collateralRBTCWei * price0) / 1e18;
            ratioBps = type(uint256).max;
            health = 0;
            return (collateralRBTCWei, borrowed, collateralValue18, ratioBps, health);
        }

        uint256 price = oracle.getMedianPrice();
        require(price > 0, "Pool: invalid oracle price");

        collateralValue18 = (collateralRBTCWei * price) / 1e18;

        // adjust collateral to debt decimals (same approach as getCollateralRatio)
        uint256 adjustedCollateral = debtTokenDecimals >= 18
            ? collateralValue18 * (10 ** (debtTokenDecimals - 18))
            : collateralValue18 / (10 ** (18 - debtTokenDecimals));

        ratioBps = (adjustedCollateral * 10000) / borrowed;

        if (ratioBps >= 20000) {
            health = 0;
        } else if (ratioBps >= 11000) {
            health = 1;
        } else {
            health = 2;
        }
        return (collateralRBTCWei, borrowed, collateralValue18, ratioBps, health);
    }

    function isOracleDeviated() external view returns (bool) {
        return oracle.isDeviated();
    }

    function getOraclePrice() external view returns (uint256) {
        return oracle.getMedianPrice();
    }

    receive() external payable {}

    // ---------- Internal ----------
    function _checkOracle() internal view {
        if (oracle.isDeviated()) revert("Pool: oracle deviated");
        require(oracle.getMedianPrice() > 0, "Pool: oracle price zero");
    }
}
