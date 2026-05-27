import { network } from "hardhat";
async function main() {
  const { ethers } = await network.connect();
  const registry = new ethers.Contract(
    "0xbE8d243C435796ee8f716CE34B5f76866E909f64",
    [
      "function CLUB_ROLE() view returns (bytes32)",
      "function hasRole(bytes32,address) view returns (bool)",
    ],
    ethers.provider
  );
  const CLUB_ROLE = await registry.CLUB_ROLE();
  console.log("Club has CLUB_ROLE:", await registry.hasRole(CLUB_ROLE, "0xF6EE621FcFceE360Bf3BbA8707144a58B0028F85"));
}
main().catch(console.error);
