import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  console.log("Attempting TransferEscrow deployment...");
  const Factory = await ethers.getContractFactory("TransferEscrow");
  const impl = await Factory.deploy();
  await impl.waitForDeployment();
  console.log("SUCCESS - deployed at:", await impl.getAddress());
  console.log("Arc does NOT enforce the 24KB limit.");
}

main().catch((e) => {
  console.error("FAILED:", e.message?.slice(0, 200));
  process.exit(1);
});
