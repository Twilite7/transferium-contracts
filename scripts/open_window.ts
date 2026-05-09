import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const TRANSFER_WINDOW = "0x8b367cCC24B3fA32055979699f1b142aD733E211";

  const abi = [
    "function scheduleWindow(string,uint256,uint256,uint8) returns (uint256)",
    "function advanceActiveWindow()",
    "function isWindowOpen() view returns (bool)",
    "function getActiveWindow() view returns (tuple(uint256 id,string label,uint256 opensAt,uint256 closesAt,bool exists))",
  ];

  const win = new ethers.Contract(TRANSFER_WINDOW, abi, deployer);

  // I get the actual on-chain block timestamp — not wall clock
  const block    = await deployer.provider.getBlock("latest");
  const chainNow = BigInt(block!.timestamp);
  console.log("Chain timestamp:", new Date(Number(chainNow) * 1000).toISOString());

  // I use 10 minutes ahead of chain time — safe margin for busy testnet
  const opensAt  = chainNow + 600n;
  const closesAt = opensAt  + 86400n * 30n;
  console.log("opensAt: ", new Date(Number(opensAt)  * 1000).toISOString());
  console.log("closesAt:", new Date(Number(closesAt) * 1000).toISOString());

  console.log("\nScheduling...");
  const tx = await win.scheduleWindow(
    "Test Window May 2026", opensAt, closesAt, 1,
    { gasLimit: 300_000n }
  );
  console.log("Tx:", tx.hash);
  await tx.wait();
  console.log("Scheduled. Waiting 620s for opensAt to pass on-chain...");

  await new Promise(r => setTimeout(r, 620_000));

  console.log("Advancing...");
  const tx2 = await win.advanceActiveWindow({ gasLimit: 150_000n });
  console.log("Tx:", tx2.hash);
  await tx2.wait();

  const open = await win.isWindowOpen();
  console.log("Window open:", open);
  if (open) {
    const active = await win.getActiveWindow();
    console.log(`"${active.label}" closes ${new Date(Number(active.closesAt) * 1000).toISOString()}`);
  }
}

main().catch(e => { console.error(e); process.exit(1); });
