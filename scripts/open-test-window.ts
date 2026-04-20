import { network } from "hardhat";
import addresses from "../deployments/addresses.json";

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();

  // I read the current block timestamp from the chain directly
  const block   = await ethers.provider.getBlock("latest");
  const chainNow = Number(block!.timestamp);

  // I open 2 minutes from chain time to avoid race conditions
  const opensAt  = chainNow + 120;
  const closesAt = chainNow + 30 * 24 * 3600;

  const windowAbi = [
    "function scheduleWindow(string calldata label, uint256 opensAt, uint256 closesAt) external returns (uint256)",
  ];

  const transferWindow = await ethers.getContractAt(windowAbi, addresses.TransferWindow, deployer);

  const tx = await transferWindow.scheduleWindow("Test Window — April 2026", opensAt, closesAt);
  await tx.wait();

  console.log(`✅ Test window scheduled`);
  console.log(`   Chain time : ${new Date(chainNow * 1000).toUTCString()}`);
  console.log(`   Opens at   : ${new Date(opensAt  * 1000).toUTCString()} (in ~2 minutes)`);
  console.log(`   Closes at  : ${new Date(closesAt * 1000).toUTCString()}`);
  console.log(`\nWait 2 minutes then run: npx hardhat run scripts/advance-window.ts --network arc`);
}

main().catch(err => { console.error(err); process.exit(1); });
