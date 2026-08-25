import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  
  const registry = await ethers.getContractAt(
    "PlayerRegistry",
    "0x21962C5548aeD0Ca83c8a1Bf051FE221CB9De4f9"
  );

  try {
    const total = await registry.totalPlayers();
    console.log("PlayerRegistry alive — totalPlayers:", total.toString());
  } catch (e: any) {
    console.log("PlayerRegistry DEAD:", e.message?.slice(0, 60));
  }

  const de = await ethers.getContractAt(
    "DealEscrow",
    "0xC81139b1732D7275097cA05055fDF8470Bb34a14"
  );

  try {
    const total = await de.totalDeals();
    console.log("DealEscrow alive — totalDeals:", total.toString());
  } catch (e: any) {
    console.log("DealEscrow DEAD:", e.message?.slice(0, 60));
  }
}

main().catch(console.error);
