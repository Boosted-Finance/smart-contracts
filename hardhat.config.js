require("@nomiclabs/hardhat-truffle5");
require("@nomiclabs/hardhat-ethers");
require("@nomiclabs/hardhat-web3");
require("@nomiclabs/hardhat-etherscan");

require('./scripts/orbVaults');
require('dotenv').config();

module.exports = {
  networks: {
    hardhat: {
      forking: {
        url: `https://eth-mainnet.alchemyapi.io/v2/${process.env.ALCHEMY_KEY}`,
        blockNumber: 12313000
      }
    },
    kovan: {
      url: `https://kovan.infura.io/v3/${process.env.INFURA_API_KEY}`,
      accounts: [process.env.PRIVATE_KEY],
      timeout: 20000
    },
    mainnet: {
      url: `https://mainnet.infura.io/v3/${process.env.INFURA_API_KEY}`,
      accounts: [process.env.PRIVATE_KEY],
      timeout: 200000
    }
  },
  solidity: {
    compilers: [
      {
        version: "0.5.17",
        optimizer: {
          enabled: true,
          runs: 100000
        }
      }
    ]
  },
  paths: {
    sources: './contracts',
    tests: './test',
  },
  mocha: {
    enableTimeouts: false,
  },
};
