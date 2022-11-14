require("@nomiclabs/hardhat-waffle");

/**
 * @type import('hardhat/config').HardhatUserConfig
 */
module.exports = {
  paths: {
    sources: "./src/contracts",
  },
  solidity: "0.8.12",
  networks: {
    localhost: {
      url: "http://127.0.0.1:8545",
      chainId: 1337,
    },
    hardhat: {
      allowUnlimitedContractSize: true,
      chainId: 1337,
    },
  },
};
