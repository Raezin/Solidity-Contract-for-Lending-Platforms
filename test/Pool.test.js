const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Lending Platform (local deploy)", function () {
  let deployer, user;
  let pool, zusd, wrbtc, oracle, adapter, borrowerOps, stability;

  async function deployAll() {
    [deployer, user] = await ethers.getSigners();

    // 1) Tokens
    const ZUSD = await ethers.getContractFactory("ZUSD");
    zusd = await ZUSD.deploy();
    await zusd.deployed();

    const WRBTC = await ethers.getContractFactory("WRBTC");
    wrbtc = await WRBTC.deploy();
    await wrbtc.deployed();

    // 2) Price feeds + oracle
    const PriceFeed1 = await ethers.getContractFactory("PriceFeed1");
    const feed1 = await PriceFeed1.deploy();
    await feed1.deployed();
    await feed1.setPrice(ethers.utils.parseEther("1"));

    const PriceFeed2 = await ethers.getContractFactory("PriceFeed2");
    const feed2 = await PriceFeed2.deploy();
    await feed2.deployed();
    await feed2.setPrice(ethers.utils.parseEther("1"));

    const OracleMedianizer = await ethers.getContractFactory("OracleMedianizer");
    oracle = await OracleMedianizer.deploy(feed1.address, feed2.address);
    await oracle.deployed();

    // 3) BorrowerOps mock
    const BorrowerOperationsMock = await ethers.getContractFactory("BorrowerOperationsMock");
    borrowerOps = await BorrowerOperationsMock.deploy(zusd.address, wrbtc.address, oracle.address, 0);
    await borrowerOps.deployed();

    await zusd.transferOwnership(borrowerOps.address);
    await wrbtc.transferOwnership(borrowerOps.address);

    // 4) Adapter + stability + pool
    const SovrynAdapterWithProxies = await ethers.getContractFactory("SovrynAdapterWithProxies");
    adapter = await SovrynAdapterWithProxies.deploy(borrowerOps.address, zusd.address, deployer.address);
    await adapter.deployed();

    const StabilityPoolMock = await ethers.getContractFactory("StabilityPoolMock");
    stability = await StabilityPoolMock.deploy(zusd.address, wrbtc.address);
    await stability.deployed();

    await borrowerOps.setStabilityPool(stability.address);

    const Pool = await ethers.getContractFactory("Pool");
    pool = await Pool.deploy(
      adapter.address,
      oracle.address,
      zusd.address,
      ethers.utils.parseEther("10000"),     // per-wallet cap
      ethers.utils.parseEther("1000000")    // system cap
    );
    await pool.deployed();

    await adapter.setPool(pool.address);

    return { feed1, feed2 };
  }

  beforeEach(async () => {
    await deployAll();
  });

  it("should open a loan (openTrove)", async () => {
    const tx = await pool.connect(user).openTrove(
      0,
      ethers.utils.parseEther("500"),      // borrow amount
      { value: ethers.utils.parseEther("5") } // collateral
    );
    const receipt = await tx.wait();
    console.log("LoanOpened tx:", receipt.transactionHash);

    expect(await pool.totalBorrowed()).to.equal(ethers.utils.parseEther("500"));
    const bal = await zusd.balanceOf(user.address);
    expect(bal).to.equal(ethers.utils.parseEther("500"));
  });

  it("should add collateral", async () => {
    await pool.connect(user).openTrove(
      0,
      ethers.utils.parseEther("500"),
      { value: ethers.utils.parseEther("5") }
    );

    const tx = await pool.connect(user).addCollateral({ value: ethers.utils.parseEther("1") });
    const receipt = await tx.wait();
    console.log("CollateralAdded tx:", receipt.transactionHash);
  });

  it("should repay partially", async () => {
    await pool.connect(user).openTrove(
      0,
      ethers.utils.parseEther("500"),
      { value: ethers.utils.parseEther("5") }
    );

    await zusd.connect(user).approve(adapter.address, ethers.utils.parseEther("200"));

    const tx = await pool.connect(user).repay(ethers.utils.parseEther("200"));
    const receipt = await tx.wait();
    console.log("Repaid tx:", receipt.transactionHash);

    const debtLeft = await pool.totalBorrowed();
    expect(debtLeft).to.equal(ethers.utils.parseEther("300"));
  });

  it("should fail when wallet cap exceeded", async () => {
    await pool.connect(deployer).setCaps(
      ethers.utils.parseEther("50"),
      ethers.utils.parseEther("1000000")
    );

    await expect(
      pool.connect(user).openTrove(0, ethers.utils.parseEther("100"), { value: ethers.utils.parseEther("5") })
    ).to.be.revertedWith("Pool: per-wallet cap exceeded");
  });

  it("should fail when oracle deviation is high", async () => {
    const PriceFeed1 = await ethers.getContractFactory("PriceFeed1");
    const PriceFeed2 = await ethers.getContractFactory("PriceFeed2");
    const feed1 = await PriceFeed1.attach(await oracle.feed1());
    const feed2 = await PriceFeed2.attach(await oracle.feed2());

    await feed1.setPrice(ethers.utils.parseEther("1"));
    await feed2.setPrice(ethers.utils.parseEther("1000"));

    await expect(
      pool.connect(user).openTrove(0, ethers.utils.parseEther("100"), { value: ethers.utils.parseEther("5") })
    ).to.be.revertedWith("Pool: oracle deviated");
  });

  it("should allow repay even when oracle deviated", async () => {
    await pool.connect(user).openTrove(
      0,
      ethers.utils.parseEther("500"),
      { value: ethers.utils.parseEther("5") }
    );

    // push feeds apart
    const PriceFeed1 = await ethers.getContractFactory("PriceFeed1");
    const PriceFeed2 = await ethers.getContractFactory("PriceFeed2");
    const feed1 = await PriceFeed1.attach(await oracle.feed1());
    const feed2 = await PriceFeed2.attach(await oracle.feed2());
    await feed1.setPrice(ethers.utils.parseEther("1"));
    await feed2.setPrice(ethers.utils.parseEther("1000"));

    await zusd.connect(user).approve(adapter.address, ethers.utils.parseEther("100"));
    const tx = await pool.connect(user).repay(ethers.utils.parseEther("100"));
    const receipt = await tx.wait();
    console.log("Repaid (deviation allowed) tx:", receipt.transactionHash);
  });

  it("should allow repay when paused", async () => {
    await pool.connect(user).openTrove(
      0,
      ethers.utils.parseEther("500"),
      { value: ethers.utils.parseEther("5") }
    );

    await pool.connect(deployer).pause();

    await zusd.connect(user).approve(adapter.address, ethers.utils.parseEther("50"));
    const tx = await pool.connect(user).repay(ethers.utils.parseEther("50"));
    const receipt = await tx.wait();
    console.log("Repaid (paused allowed) tx:", receipt.transactionHash);
  });
});
