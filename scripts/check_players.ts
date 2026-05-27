import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();

  const registry = new ethers.Contract(
    "0x4EB83Ae9092b154fB87C5c17632b3aa181AD3201",
    [
      "function totalPlayers() view returns (uint256)",
      "function getPlayer(uint256) view returns (tuple(uint256 id,string name,string position,string nationality,uint256 contractExpiry,uint256 weeklySalary,address playerWallet,bool isVerified,bool isListed,bool medicalClearance,bytes32 medicalDocumentHash,uint256 askingPrice,uint256 releaseClause,uint256 registeredAt,string portraitCID,bytes32 fifaId))",
      "function ownerOf(uint256) view returns (address)",
    ],
    deployer
  );

  const total = await registry.totalPlayers();
  console.log("Total players:", total.toString());

  for (let i = 1n; i <= total; i++) {
    const p     = await registry.getPlayer(i);
    const owner = await registry.ownerOf(i);
    console.log(`#${i}: ${p.name} | pos: ${p.position} | owner: ${owner} | verified: ${p.isVerified}`);
  }
}

main().catch(console.error);
