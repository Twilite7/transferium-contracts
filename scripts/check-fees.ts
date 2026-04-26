import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  const registry = await ethers.getContractAt(
    ["function registrationFee() external view returns (uint256)",
     "function listingFee() external view returns (uint256)"],
    "0x9330201B9e5ad815f19cbf1522BD76D2fe035512"
  );
  console.log("Registration fee:", (await registry.registrationFee()).toString());
  console.log("Listing fee:     ", (await registry.listingFee()).toString());
}
main().catch(console.error);

async function check() {
  const { ethers } = await network.connect();
  const registry = await ethers.getContractAt(
    ["function totalPlayers() external view returns (uint256)"],
    "0x9330201B9e5ad815f19cbf1522BD76D2fe035512"
  );
  console.log("Total players:", (await registry.totalPlayers()).toString());
}
check().catch(console.error);
