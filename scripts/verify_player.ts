import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();

  const registry = new ethers.Contract(
    "0x983B1e2e39C534762841932b526D3f145110b38A",
    [
      "function verifyPlayer(uint256 playerId) external",
      "function getPlayer(uint256 playerId) view returns (tuple(string name, string position, string nationality, uint256 contractExpiry, uint256 weeklySalary, string portraitCID, bytes32 fifaId, address club, bool verified))",
    ],
    deployer
  );

  for (let id = 1n; id <= 5n; id++) {
    try {
      const p = await registry.getPlayer(id);
      console.log(`#${id}: ${p.name} | club: ${p.club} | verified: ${p.verified}`);
    } catch { console.log(`#${id}: not found`); }
  }
}

main().catch(console.error);
