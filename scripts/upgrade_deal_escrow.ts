import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();
  const PROXY   = "0xC81139b1732D7275097cA05055fDF8470Bb34a14";
  const FEE_LIB = "0x25DA35EDB34f227ED39C8352c7aa17cE20bffe0b";

  const Factory = await ethers.getContractFactory("DealEscrow", {
    signer: deployer,
    libraries: { FeeLib: FEE_LIB },
  });
  const impl = await Factory.deploy();
  await impl.waitForDeployment();
  console.log("New impl:", await impl.getAddress());

  const proxy = new ethers.Contract(PROXY, [
    "function upgradeToAndCall(address,bytes) external",
  ], deployer);
  await (await proxy.upgradeToAndCall(await impl.getAddress(), "0x")).wait();
  console.log("✅ DealEscrow upgraded");

  const de = await ethers.getContractAt("DealEscrow", PROXY, deployer);
  const r  = await de.getDealFull(1).catch(() => null);
  console.log("getDealFull(1) exists:", r ? r[0] : "no deal 1");
}

main().catch(console.error);
