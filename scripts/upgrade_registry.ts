import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  ethers.provider.pollingInterval = 15000; // slow polling — Arc RPC rate-limits at 30 req/60s
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const PROXY = "0x21962C5548aeD0Ca83c8a1Bf051FE221CB9De4f9"; // corrected: actual current live proxy per deployments/addresses.json

  const Factory = await ethers.getContractFactory("PlayerRegistry", deployer);
  const impl    = await Factory.deploy();
  await impl.waitForDeployment();
  const implAddr = await impl.getAddress();
  console.log("New implementation:", implAddr);

  const proxy = new ethers.Contract(PROXY, [
    "function upgradeToAndCall(address newImplementation, bytes calldata data) external",
    "function verificationActive(uint256) view returns (bool)",
    "function walletToPlayer(address) view returns (uint256)",
    "function totalPlayers() view returns (uint256)",
    "function getPlayer(uint256) view returns (tuple(address playerWallet, uint256 askingPrice, uint256 releaseClause, bool isListed, bool medicalClearance, bool medicalVerified, bytes32 medicalDocumentHash))",
  ], deployer);

  await (await proxy.upgradeToAndCall(implAddr, "0x")).wait();
  console.log("✅ Upgrade complete");

  // Verify new functions are live
  try {
    const active = await proxy.verificationActive(1);
    console.log("verificationActive(1):", active);
  } catch (e: any) {
    console.log("❌ verificationActive failed:", e.message?.slice(0, 80));
  }
  // Confirm existing state survived the storage-layout change (added _operationalRoleCount)
  try {
    const total = await proxy.totalPlayers();
    console.log("totalPlayers():", total.toString());
  } catch (e: any) {
    console.log("❌ totalPlayers failed:", e.message?.slice(0, 80));
  }
}

main().catch(e => { console.error(e); process.exit(1); });
