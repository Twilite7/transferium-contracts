import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();

  // 1. Deploy FeeLib first
  console.log("Deploying FeeLib...");
  const FeeLibF = await ethers.getContractFactory("FeeLib");
  const feeLib  = await FeeLibF.deploy();
  await feeLib.waitForDeployment();
  const feeLibAddr = await feeLib.getAddress();
  console.log("FeeLib:", feeLibAddr);

  // 2. Deploy DealEscrow linked to FeeLib
  console.log("Deploying DealEscrow...");
  const DealF = await ethers.getContractFactory("DealEscrow", {
    libraries: { FeeLib: feeLibAddr }
  });
  const dealImpl = await DealF.deploy();
  await dealImpl.waitForDeployment();
  console.log("DealEscrow impl:", await dealImpl.getAddress());

  // 3. Deploy TransferEscrow (no library deps)
  console.log("Deploying TransferEscrow...");
  const TEF     = await ethers.getContractFactory("TransferEscrow");
  const teImpl  = await TEF.deploy();
  await teImpl.waitForDeployment();
  console.log("TransferEscrow impl:", await teImpl.getAddress());

  console.log("SUCCESS — all three fit on Arc.");
}

main().catch(e => {
  console.error("FAILED:", e.message?.slice(0, 300));
  process.exit(1);
});
