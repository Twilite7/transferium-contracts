import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();

  const registry = new ethers.Contract(
    "0xbE8d243C435796ee8f716CE34B5f76866E909f64",
    ["function setClubName(address club, string calldata name) external"],
    deployer
  );

  await (await registry.setClubName("0xF6EE621FcFceE360Bf3BbA8707144a58B0028F85", "FC Barcelona")).wait();
  console.log("Club name set");
}

main().catch(console.error);
