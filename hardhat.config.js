require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

module.exports = {
  solidity: "0.8.28",
  networks: {
    hardhat: {}, // local in-memory blockchain
    rskTestnet: {
      url: process.env.RSK_TESTNET_RPC,
      accounts: [process.env.PRIVATE_KEY],
      chainId: 31,
    },
  },
};
