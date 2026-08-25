import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  ethers.provider.pollingInterval = 15000;
  const REGISTRY = "0x21962C5548aeD0Ca83c8a1Bf051FE221CB9De4f9";
  const DEPLOYER = "0x13E569C96c7F884443d0c3Ac5019D020dE32bFb3";
  const registry = await ethers.getContractAt("PlayerRegistry", REGISTRY);
  const hasDefaultAdmin = await registry.hasRole(ethers.ZeroHash, DEPLOYER);
  console.log("Deployer holds DEFAULT_ADMIN_ROLE:", hasDefaultAdmin);
}

main().catch(console.error);
