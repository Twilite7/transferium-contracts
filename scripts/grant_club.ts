import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();

  const registry = new ethers.Contract(
    "0x4EB83Ae9092b154fB87C5c17632b3aa181AD3201",
    [
      "function CLUB_ROLE() view returns (bytes32)",
      "function grantRole(bytes32,address) external",
      "function hasRole(bytes32,address) view returns (bool)",
    ],
    deployer
  );

  const CLUB_ROLE  = await registry.CLUB_ROLE();
  const club       = "0xF6EE621FcFceE360Bf3BbA8707144a58B0028F85";

  await (await registry.grantRole(CLUB_ROLE, club)).wait();
  console.log("CLUB_ROLE granted:", await registry.hasRole(CLUB_ROLE, club));
}

main().catch(console.error);
