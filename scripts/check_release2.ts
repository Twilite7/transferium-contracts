import { network } from "hardhat";
async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();
  const RELEASE = "0xf1ce6CC66A5cE8Cae8d0f73Ee57027AdfD2F0c2F";
  const code = await ethers.provider.getCode(RELEASE);
  console.log("Code length:", code.length);
  // Check EIP-1967 impl slot
  const implSlot = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
  const implRaw = await ethers.provider.getStorage(RELEASE, implSlot);
  const impl = "0x" + implRaw.slice(-40);
  console.log("Impl slot:", impl);
  console.log("Is zero?", impl === "0x0000000000000000000000000000000000000000");
  // Check addresses.json for actual deployed address
  const fs = require("fs");
  const addrs = JSON.parse(fs.readFileSync("/home/kali/transferium-contracts/deployments/addresses.json", "utf8"));
  console.log("addresses.json ReleaseEscrow:", addrs.ReleaseEscrow);
}
main().catch(console.error);
