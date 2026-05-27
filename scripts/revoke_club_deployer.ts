import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();

  const registry = new ethers.Contract(
    "0x4EB83Ae9092b154fB87C5c17632b3aa181AD3201",
    [
      "function CLUB_ROLE() view returns (bytes32)",
      "function revokeRole(bytes32,address) external",
      "function hasRole(bytes32,address) view returns (bool)",
    ],
    deployer
  );

  const CLUB_ROLE = await registry.CLUB_ROLE();
  await (await registry.revokeRole(CLUB_ROLE, deployer.address)).wait();
  console.log("CLUB_ROLE revoked:", await registry.hasRole(CLUB_ROLE, deployer.address));
}

main().catch(console.error);
