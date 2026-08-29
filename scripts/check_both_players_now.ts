import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  ethers.provider.pollingInterval = 15000;

  const REGISTRY = "0x21962C5548aeD0Ca83c8a1Bf051FE221CB9De4f9";
  const registry = await ethers.getContractAt("PlayerRegistry", REGISTRY);

  for (const id of [1, 2]) {
    const player = await registry.getPlayer(id);
    console.log(`Player ${id} wallet:`, player.playerWallet);
  }
}

main().catch(console.error);
