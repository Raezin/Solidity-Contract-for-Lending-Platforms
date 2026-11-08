// scripts/devdeploy.js
const hre = require("hardhat");
const { ethers } = hre;
const fs = require("fs");
const path = require("path");
require("dotenv").config(); // load RPC + PRIVATE_KEY

// Save contract addresses to deployed.json
async function saveAddresses(name, contract) {
  const filePath = path.join(__dirname, "..", "deployed.json");
  let data = {};
  if (fs.existsSync(filePath)) {
    data = JSON.parse(fs.readFileSync(filePath, "utf8"));
  }
  const network = hre.network.name;
  if (!data[network]) data[network] = {};
  data[network][name] = contract.address;
  fs.writeFileSync(filePath, JSON.stringify(data, null, 2));
}

async function logOwner(label, contract) {
  try {
    const owner = await contract.owner();
    console.log(`${label} owner: ${owner}`);
  } catch {
    /* ignore */
  }
}

async function main() {
  const provider = new ethers.providers.JsonRpcProvider(process.env.RSK_TESTNET_RPC);
  const deployer = new ethers.Wallet(process.env.PRIVATE_KEY, provider);

  console.log("Deploying contracts with account:", deployer.address);

  // ---------------- 1. Deploy ZUSD ----------------
  const ZUSD = await ethers.getContractFactory("ZUSD", deployer);
  const zusd = await ZUSD.deploy();
  await zusd.deployed();
  console.log("ZUSD deployed to:", zusd.address);
  await saveAddresses("ZUSD", zusd);

  // ---------------- 2. Deploy WRBTC ----------------
  const WRBTC = await ethers.getContractFactory("WRBTC", deployer);
  const wrbtc = await WRBTC.deploy();
  await wrbtc.deployed();
  console.log("WRBTC deployed to:", wrbtc.address);
  await saveAddresses("WRBTC", wrbtc);

  // ---------------- 3. Deploy PriceFeeds ----------------
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

  // ---------------- 4. Deploy OracleMedianizer ----------------
  const OracleMedianizer = await ethers.getContractFactory("OracleMedianizer", deployer);
  const oracle = await OracleMedianizer.deploy(feed1.address, feed2.address);
  await oracle.deployed();
  console.log("OracleMedianizer deployed to:", oracle.address);
  await saveAddresses("OracleMedianizer", oracle);

  // ---------------- 5. Deploy BorrowerOperationsMock ----------------
  const BorrowerOperationsMock = await ethers.getContractFactory("BorrowerOperationsMock", deployer);
  const borrowerOpsMock = await BorrowerOperationsMock.deploy(
    zusd.address,
    wrbtc.address,
    oracle.address,
    0 // baseRateBps = zero interest for client
  );
  await borrowerOpsMock.deployed();
  console.log("BorrowerOperationsMock deployed to:", borrowerOpsMock.address);
  await saveAddresses("BorrowerOperationsMock", borrowerOpsMock);
  await logOwner("BorrowerOperationsMock", borrowerOpsMock);

  // Transfer token ownerships to BorrowerOperationsMock
  await (await zusd.transferOwnership(borrowerOpsMock.address)).wait();
  await (await wrbtc.transferOwnership(borrowerOpsMock.address)).wait();
  console.log("Token ownerships transferred to BorrowerOperationsMock");

  // ---------------- 6. Deploy SovrynAdapterWithProxies ----------------
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

  // ---------------- 7. Deploy StabilityPoolMock ----------------
  const StabilityPoolMock = await ethers.getContractFactory("StabilityPoolMock", deployer);
  const stabilityPool = await StabilityPoolMock.deploy(zusd.address, wrbtc.address);
  await stabilityPool.deployed();
  console.log("StabilityPoolMock deployed to:", stabilityPool.address);
  await saveAddresses("StabilityPoolMock", stabilityPool);

  await (await borrowerOpsMock.setStabilityPool(stabilityPool.address)).wait();
  console.log("BorrowerOperationsMock stability pool set");

  // ---------------- 8. Deploy Pool ----------------
  const Pool = await ethers.getContractFactory("Pool", deployer);
  const pool = await Pool.deploy(
    adapter.address,
    oracle.address,
    zusd.address,
    ethers.utils.parseUnits("10000", 18),   // per-wallet cap
    ethers.utils.parseUnits("1000000", 18), // protocol cap
    deployer.address                        // owner
  );
  await pool.deployed();
  console.log("Pool deployed to:", pool.address);
  await saveAddresses("Pool", pool);
  await logOwner("Pool", pool);

  // ---------------- 9. Wire up & set parameters BEFORE ownership transfer ----------------
  await (await adapter.setPool(pool.address)).wait();
  console.log("Adapter pool set to Pool address");

  // Set parameters directly on BorrowerOperationsMock BEFORE ownership transfer
  await (await borrowerOpsMock.setMinCollateralRatioBps(11000)).wait(); // 110%
  await (await borrowerOpsMock.setBaseRateBps(0)).wait();               // 0% interest (as per client)
  await (await borrowerOpsMock.setOracle(oracle.address)).wait();
  console.log("BorrowerOperationsMock parameters set (minCR=150%, baseRate=0, oracle)");

  // ---------------- 10. Transfer BorrowerOpsMock ownership to Adapter ----------------
  await (await borrowerOpsMock.transferOwnership(adapter.address)).wait();
  console.log("BorrowerOperationsMock ownership transferred to Adapter");
  await logOwner("BorrowerOperationsMock", borrowerOpsMock);

  // ---------------- Done ----------------
  console.log("\n--- Deployment completed successfully! ---\n");
  console.log("Deployer:", deployer.address);
  console.log("ZUSD:", zusd.address);
  console.log("WRBTC:", wrbtc.address);
  console.log("Oracle:", oracle.address);
  console.log("Pool:", pool.address);
  console.log("StabilityPoolMock:", stabilityPool.address);
  console.log("Adapter:", adapter.address);
  console.log("BorrowerOpsMock:", borrowerOpsMock.address);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
