// scripts/deploy-bypass.js
const hre = require("hardhat");
const { ethers } = hre;
const fs = require("fs");
const path = require("path");

// -----------------------------------------------------
// helpers
// -----------------------------------------------------
async function saveAddresses(name, contract) {
  const filePath = path.join(__dirname, "..", "deployed.json");
  let data = {};
  if (fs.existsSync(filePath)) data = JSON.parse(fs.readFileSync(filePath, "utf8"));
  const network = hre.network.name;
  if (!data[network]) data[network] = {};
  data[network][name] = contract.address;
  fs.writeFileSync(filePath, JSON.stringify(data, null, 2));
}

async function logOwner(label, contract) {
  try {
    const owner = await contract.owner();
    console.log(`${label} owner: ${owner}`);
  } catch { /* ignore */ }
}

async function main() {
  const [deployer, user1, user2] = await ethers.getSigners();

  console.log("Local deployer account:", deployer.address);
  console.log("Local user1 account:", user1.address);
  console.log("Local user2 account:", user2.address);

  // ---------------- Deploy tokens ----------------
  const ZUSD = await ethers.getContractFactory("ZUSD", deployer);
  const zusd = await ZUSD.deploy();
  await zusd.deployed();
  console.log("ZUSD deployed to:", zusd.address);
  await saveAddresses("ZUSD", zusd);

  const WRBTC = await ethers.getContractFactory("WRBTC", deployer);
  const wrbtc = await WRBTC.deploy();
  await wrbtc.deployed();
  console.log("WRBTC deployed to:", wrbtc.address);
  await saveAddresses("WRBTC", wrbtc);

  // ---------------- Deploy PriceFeeds ----------------
  const PriceFeed1 = await ethers.getContractFactory("PriceFeed1", deployer);
  const feed1 = await PriceFeed1.deploy();
  await feed1.deployed();
  console.log("PriceFeed1 deployed to:", feed1.address);
  await saveAddresses("PriceFeed1", feed1);

  const PriceFeed2 = await ethers.getContractFactory("PriceFeed2", deployer);
  const feed2 = await PriceFeed2.deploy();
  await feed2.deployed();
  console.log("PriceFeed2 deployed to:", feed2.address);
  await saveAddresses("PriceFeed2", feed2);

  // (optional) set initial prices so ratio math is sane during deploy/tests
  await (await feed1.setPrice(ethers.utils.parseUnits("60000", 18))).wait();
  await (await feed2.setPrice(ethers.utils.parseUnits("60000", 18))).wait();

  // ---------------- Deploy Oracle ----------------
  const OracleMedianizer = await ethers.getContractFactory("OracleMedianizer", deployer);
  const oracle = await OracleMedianizer.deploy(feed1.address, feed2.address);
  await oracle.deployed();
  console.log("OracleMedianizer deployed to:", oracle.address);
  await saveAddresses("OracleMedianizer", oracle);

  // ---------------- Deploy BorrowerOperationsMock ----------------
  const BorrowerOperationsMock = await ethers.getContractFactory("BorrowerOperationsMock", deployer);
  const borrowerOpsMock = await BorrowerOperationsMock.deploy(
    zusd.address,
    wrbtc.address,
    oracle.address,
    0 // baseRateBps
  );
  await borrowerOpsMock.deployed();
  console.log("BorrowerOperationsMock deployed to:", borrowerOpsMock.address);
  await saveAddresses("BorrowerOperationsMock", borrowerOpsMock);
  await logOwner("BorrowerOperationsMock", borrowerOpsMock);

  // Transfer token ownership to BorrowerOperationsMock (so it can mint/burn)
  await (await zusd.transferOwnership(borrowerOpsMock.address)).wait();
  await (await wrbtc.transferOwnership(borrowerOpsMock.address)).wait();
  console.log("Token ownerships transferred to BorrowerOperationsMock");

  // ---------------- Deploy Adapter ----------------
  const SovrynAdapterWithProxies = await ethers.getContractFactory("SovrynAdapterWithProxies", deployer);
  const adapter = await SovrynAdapterWithProxies.deploy(
    borrowerOpsMock.address,
    zusd.address,
    wrbtc.address
  );
  await adapter.deployed();
  console.log("SovrynAdapterWithProxies deployed to:", adapter.address);
  await saveAddresses("SovrynAdapterWithProxies", adapter);
  await logOwner("Adapter", adapter);

  // ---------------- Deploy StabilityPoolMock ----------------
  const StabilityPoolMock = await ethers.getContractFactory("StabilityPoolMock", deployer);
  const stabilityPool = await StabilityPoolMock.deploy(zusd.address, wrbtc.address);
  await stabilityPool.deployed();
  console.log("StabilityPoolMock deployed to:", stabilityPool.address);
  await saveAddresses("StabilityPoolMock", stabilityPool);

  // Set stability pool BEFORE transferring BorrowerOps ownership to Adapter
  await (await borrowerOpsMock.setStabilityPool(stabilityPool.address)).wait();
  console.log("BorrowerOperationsMock stability pool set");

  // ---------------- Deploy Pool ----------------
  const Pool = await ethers.getContractFactory("Pool", deployer);
  const pool = await Pool.deploy(
    adapter.address,
    oracle.address,
    zusd.address,
    ethers.utils.parseUnits("10000", 18),   // perWalletCap
    ethers.utils.parseUnits("1000000", 18), // protocolCap
    deployer.address                        // _owner
  );
  await pool.deployed();
  console.log("Pool deployed to:", pool.address);
  await saveAddresses("Pool", pool);
  await logOwner("Pool", pool);

  // ---------------- Wire up & set owners in the RIGHT order ----------------

  // 1) Point Adapter to Pool
  await (await adapter.setPool(pool.address)).wait();
  console.log("Adapter pool set to Pool address");

  // 2) Set parameters directly on BorrowerOperationsMock BEFORE ownership transfer
  await (await borrowerOpsMock.setMinCollateralRatioBps(15000)).wait(); // 150%
  await (await borrowerOpsMock.setBaseRateBps(500)).wait();             // 5%
  await (await borrowerOpsMock.setOracle(oracle.address)).wait();
  console.log("BorrowerOperationsMock parameters set (minCR, baseRate, oracle)");

  // 3) Transfer ownership of BorrowerOperationsMock to the Adapter
  await (await borrowerOpsMock.transferOwnership(adapter.address)).wait();
  console.log("BorrowerOperationsMock ownership transferred to Adapter");
  await logOwner("BorrowerOperationsMock", borrowerOpsMock);

  // 4) Done — skip adapter forwarded setters for now

  console.log("\n--- Ownership summary ---");
  await logOwner("Adapter", adapter);
  await logOwner("BorrowerOperationsMock", borrowerOpsMock);
  await logOwner("Pool", pool);

  console.log("\n--- Local deployment completed successfully! ---\n");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
