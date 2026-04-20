import { network } from "hardhat";
import addresses from "../deployments/addresses.json";

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();
  const windowAbi  = ["function advanceActiveWindow() external", "function isWindowOpen() external view returns (bool)"];
  const win = await ethers.getContractAt(windowAbi, addresses.TransferWindow, deployer);
  await (await win.advanceActiveWindow()).wait();
  console.log(`Window open: ${await win.isWindowOpen()}`);
}

main().catch(err => { console.error(err); process.exit(1); });
