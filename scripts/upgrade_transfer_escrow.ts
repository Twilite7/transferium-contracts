import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();
  const PROXY = "0x1bA3D6557dA3A6a861b2D27596c3c22A75c6c535";

  const Factory = await ethers.getContractFactory("TransferEscrow", deployer);
  const impl    = await Factory.deploy();
  await impl.waitForDeployment();
  console.log("New impl:", await impl.getAddress());

  const proxy = new ethers.Contract(PROXY, [
    "function upgradeToAndCall(address,bytes) external",
  ], deployer);

  await (await proxy.upgradeToAndCall(await impl.getAddress(), "0x")).wait();
  console.log("✅ TransferEscrow upgraded");

  // Verify the existing bid is now visible via getBidCount
  const escrow = await ethers.getContractAt("TransferEscrow", PROXY, deployer);
  const count  = await escrow.getBidCount(1);
  console.log("getBidCount(1):", count.toString(), "(should still be 1)");
}

main().catch(console.error);
