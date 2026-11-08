// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./BorrowerOperationsMock.sol";
import "./ZUSD.sol";
import "./WRBTC.sol";
import "./UserProxy.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract SovrynAdapterWithProxies is ReentrancyGuard, Ownable {
    using SafeERC20 for ZUSD;
    using SafeERC20 for WRBTC;

    BorrowerOperationsMock public borrowerOps;
    ZUSD public zusd;
    WRBTC public wrbtc;
    address public pool;
    bool public paused;

    mapping(address => UserProxy) public userProxy;

    // -------- Events --------
    event ProxyCreated(address indexed user, address proxy);
    event PoolSet(address indexed pool);
    event Paused();
    event Unpaused();

    // -------- Modifiers --------
    modifier onlyPoolOrOwner() {
        require(msg.sender == pool || msg.sender == owner(), "Adapter: not pool/owner");
        _;
    }

    modifier notPaused() {
        require(!paused, "Adapter: paused");
        _;
    }

    constructor(address _borrowerOps, address _zusd, address _wrbtc) {
        require(_borrowerOps != address(0) && _zusd != address(0) && _wrbtc != address(0), "Adapter: zero address");
        borrowerOps = BorrowerOperationsMock(_borrowerOps);
        zusd = ZUSD(_zusd);
        wrbtc = WRBTC(_wrbtc);
        paused = false;
    }

    // -------- Admin --------
    function setPool(address _pool) external onlyOwner {
        require(_pool != address(0), "Adapter: zero pool");
        pool = _pool;
        emit PoolSet(_pool);
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused();
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused();
    }

    function setMinCollateralRatioBps(uint256 bps) external onlyOwner {
        borrowerOps.setMinCollateralRatioBps(bps);
    }

    function setBaseRateBps(uint256 bps) external onlyOwner {
        borrowerOps.setBaseRateBps(bps);
    }

    function setOracle(address oracle) external onlyOwner {
        borrowerOps.setOracle(oracle);
    }

    // -------- Proxy management --------
    function getOrCreateProxy(address user) public returns (UserProxy) {
        UserProxy p = userProxy[user];
        if (address(p) == address(0)) {
            UserProxy newProxy = new UserProxy();
            newProxy.initialize(user, address(borrowerOps), address(this));
            userProxy[user] = newProxy;
            emit ProxyCreated(user, address(newProxy));
            return newProxy;
        }
        return p;
    }

    function proxyOf(address user) external view returns (address) {
        return address(userProxy[user]);
    }

    // -------- Forwarded functions --------

    /// Deposit collateral only (RBTC → BorrowerOperationsMock handles WRBTC wrapping)
    function depositCollateralFor(address user) 
        external 
        payable 
        notPaused 
        onlyPoolOrOwner 
        nonReentrant 
    {
        require(msg.value > 0, "Adapter: zero collateral");
        UserProxy p = getOrCreateProxy(user);
        p.addColl{value: msg.value}();
    }

    /// Open trove with collateral + borrow
    function openTroveFor(address user, uint256 maxFeeBps, uint256 zusdAmount) 
        external 
        payable 
        notPaused 
        onlyPoolOrOwner 
        nonReentrant 
    {
        UserProxy p = getOrCreateProxy(user);
        p.openTrove{value: msg.value}(maxFeeBps, zusdAmount);
    }

    /// Withdraw ZUSD to user
    function withdrawZUSDFor(address user, uint256 maxFeeBps, uint256 zusdAmount) 
        external 
        notPaused 
        onlyPoolOrOwner 
        nonReentrant 
    {
        require(zusdAmount > 0, "Adapter: zero withdraw");
        UserProxy p = getOrCreateProxy(user);
        p.withdrawZUSD(maxFeeBps, zusdAmount);
    }

    /// Repay ZUSD
    /// Repay ZUSD
/// Pull user's ZUSD into BorrowerOperationsMock (which does the burn),
/// then call repay on BorrowerOperationsMock.
/// NOTE: user must approve this Adapter to spend ZUSD.
function repayZUSDFor(address user, uint256 amount)
    external
    // NOTE: no notPaused here; allow repayments even when paused
    onlyPoolOrOwner
    nonReentrant
{
    require(amount > 0, "Adapter: zero repay");

    // 1 Pull tokens from user into BOM (BOM.burn() burns from its own balance)
    zusd.safeTransferFrom(user, address(borrowerOps), amount);

    // 2 Call via the user's proxy so BOM._detectUser() resolves to the real owner
    UserProxy p = getOrCreateProxy(user);
    p.repayZUSD(amount);
}


    /// Withdraw collateral
    function withdrawCollFor(address user, uint256 amount) 
        external 
        notPaused 
        onlyPoolOrOwner 
        nonReentrant 
    {
        require(amount > 0, "Adapter: zero withdraw");
        UserProxy p = getOrCreateProxy(user);
        p.withdrawColl(amount);
    }

    /// Close trove
    function closeTroveFor(address user) 
        external 
        onlyPoolOrOwner 
        nonReentrant 
    {
        UserProxy p = getOrCreateProxy(user);
        p.closeTrove();
    }

    receive() external payable {}
}
