import { network } from "hardhat";
import addresses from "../deployments/addresses.json";

const PLAYER_ID = 1;

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();

  const abi = [
    "function verifyPlayer(uint256 playerId) external",
    "function getPlayer(uint256 playerId) external view returns (tuple(uint256 id, string name, string position, string nationality, uint256 contractExpiry, address currentClub, bool isVerified, bool isListed, uint256 askingPrice, uint256 registeredAt))",
  ];

  const registry = await ethers.getContractAt(abi, addresses.PlayerRegistry, deployer);

  console.log(`Verifying player #${PLAYER_ID}...`);
  const tx = await registry.verifyPlayer(PLAYER_ID);
  await tx.wait();

  const player = await registry.getPlayer(PLAYER_ID);
  console.log(`✅ Player verified`);
  console.log(`   Name       : ${player.name}`);
  console.log(`   Position   : ${player.position}`);
  console.log(`   Verified   : ${player.isVerified}`);
}

main().catch(err => { console.error(err); process.exit(1); });
