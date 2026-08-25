import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  ethers.provider.pollingInterval = 15000;

  const REGISTRY = "0x21962C5548aeD0Ca83c8a1Bf051FE221CB9De4f9";
  const registry = await ethers.getContractAt("PlayerRegistry", REGISTRY);

  const player = await registry.getPlayer(2);
  console.log("Player 2 current wallet:", player.playerWallet);
  console.log("Expected problematic wallet: 0x14F94f8bf5223C2a8BA90092c0F97dfF834C8Bba");
  console.log("Match:", player.playerWallet.toLowerCase() === "0x14F94f8bf5223C2a8BA90092c0F97dfF834C8Bba".toLowerCase());
}

main().catch(console.error);
