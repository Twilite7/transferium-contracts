import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  const registry = await ethers.getContractAt(
    ["function getPlayer(uint256) external view returns (tuple(uint256 id, string name, string position, string nationality, uint256 contractExpiry, uint256 weeklySalary, address playerWallet, bool isVerified, bool isListed, bool medicalClearance, bytes32 medicalDocumentHash, uint256 askingPrice, uint256 releaseClause, uint256 registeredAt))"],
    "0x9330201B9e5ad815f19cbf1522BD76D2fe035512"
  );
  const p = await registry.getPlayer(1);
  console.log("id          :", p.id?.toString());
  console.log("name        :", p.name);
  console.log("position    :", p.position);
  console.log("nationality :", p.nationality);
  console.log("weeklySalary:", p.weeklySalary?.toString());
  console.log("isVerified  :", p.isVerified);
  console.log("registeredAt:", p.registeredAt?.toString());
}
main().catch(console.error);
