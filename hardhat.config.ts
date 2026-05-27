import hardhatToolboxMochaEthersPlugin from "@nomicfoundation/hardhat-toolbox-mocha-ethers";
import "@nomicfoundation/hardhat-verify";
import { configVariable, defineConfig } from "hardhat/config";
import "dotenv/config";

export default defineConfig({
  plugins: [hardhatToolboxMochaEthersPlugin],
  solidity: {
    profiles: {
      default: {
        version: "0.8.28",
        settings: {
          optimizer: { enabled: true, runs: 1 },
          viaIR: true,
        },
      },
      production: {
        version: "0.8.28",
        settings: {
          optimizer: { enabled: true, runs: 1 },
          viaIR: true,
        },
      },
    },
  },
  etherscan: {
    apiKey: { arc: "placeholder" },
    customChains: [
      {
        network: "arc",
        chainId: 9998,
        urls: {
          apiURL:     "https://testnet.arcscan.app/api",
          browserURL: "https://testnet.arcscan.app",
        },
      },
    ],
    enabled: false,
  },
  sourcify: {
    enabled: false,
  },
  networks: {
    hardhatLocal: {
      type: "edr-simulated",
      chainType: "l1",
    },
    arc: {
      type: "http",
      url: configVariable("ARC_RPC_URL"),
      accounts: [configVariable("DEPLOYER_PRIVATE_KEY"), configVariable("PRIVATE_KEY_CLUB"), configVariable("PRIVATE_KEY_HIJACKER")],
    },
  },
});
