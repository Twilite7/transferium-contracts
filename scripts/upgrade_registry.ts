import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const PROXY = "0xD79b972d68989f5F98b76a6bbCFFb4Cf0D79D19d";

  const Factory = await ethers.getContractFactory("PlayerRegistry", deployer);
  const impl    = await Factory.deploy();
  await impl.waitForDeployment();
  const implAddr = await impl.getAddress();
  console.log("New implementation:", implAddr);

  const proxy = new ethers.Contract(PROXY, [
    "function upgradeToAndCall(address newImplementation, bytes calldata data) external",
    "function verificationActive(uint256) view returns (bool)",
    "function walletToPlayer(address) view returns (uint256)",
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
}

main().catch(e => { console.error(e); process.exit(1); });
