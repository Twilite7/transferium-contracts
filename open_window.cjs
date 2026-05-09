const { ethers } = require("./node_modules/ethers");
const { readFileSync } = require("fs");

async function main() {
  const env     = readFileSync("/home/kali/transferium-contracts/.env", "utf8");
  const PRIVKEY = env.match(/DEPLOYER_PRIVATE_KEY=(.+)/)?.[1]?.trim();

  const RPC     = "https://rpc.testnet.arc.network";
  const ADDRESS = "0x8b367cCC24B3fA32055979699f1b142aD733E211";

  const provider = new ethers.JsonRpcProvider(RPC, undefined, { staticNetwork: true });
  const wallet   = new ethers.Wallet(PRIVKEY, provider);

  const abi = [
    "function scheduleWindow(string,uint256,uint256,uint8) returns (uint256)",
    "function advanceActiveWindow()",
    "function isWindowOpen() view returns (bool)",
    "function getActiveWindow() view returns (tuple(uint256 id,string label,uint256 opensAt,uint256 closesAt,bool exists))",
  ];

  const iface = new ethers.Interface(abi);
  const win   = new ethers.Contract(ADDRESS, abi, wallet);

  const block    = await provider.getBlock("latest");
  const chainNow = BigInt(block.timestamp);
  console.log("Chain time:", new Date(Number(chainNow) * 1000).toISOString());

  const opensAt  = chainNow + 120n;
  const closesAt = opensAt  + 86400n * 30n;
  console.log("opensAt: ", new Date(Number(opensAt)  * 1000).toISOString());
  console.log("windowType: 0 = STANDARD (max 90 days)");

  const calldata = iface.encodeFunctionData("scheduleWindow", [
    "Test Window May 2026", opensAt, closesAt, 0
  ]);

  console.log("\nScheduling...");
  const tx = await wallet.sendTransaction({ to: ADDRESS, data: calldata, gasLimit: 300000 });
  console.log("Tx:", tx.hash);
  const receipt = await tx.wait();
  console.log("Status:", receipt.status === 1 ? "SUCCESS" : "FAILED");

  if (receipt.status === 1) {
    console.log("Waiting 130s...");
    await new Promise(r => setTimeout(r, 130_000));

    console.log("Advancing...");
    const tx2 = await wallet.sendTransaction({
      to: ADDRESS,
      data: iface.encodeFunctionData("advanceActiveWindow", []),
      gasLimit: 150000,
    });
    const r2 = await tx2.wait();
    console.log("Advance:", r2.status === 1 ? "SUCCESS" : "FAILED");

    const open = await win.isWindowOpen();
    console.log("Window open:", open);
    if (open) {
      const active = await win.getActiveWindow();
      console.log(`"${active.label}" closes ${new Date(Number(active.closesAt) * 1000).toISOString()}`);
    }
  }
}

main().catch(e => { console.error(e.shortMessage ?? e.message); process.exit(1); });
