import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  ethers.provider.pollingInterval = 15000;

  for (const addr of [
    "0x21962C5548aeD0Ca83c8a1Bf051FE221CB9De4f9",
    "0xD79b972d68989f5F98b76a6bbCFFb4Cf0D79D19d",
  ]) {
    const code = await ethers.provider.getCode(addr);
    console.log(addr, "codeSize:", (code.length - 2) / 2, "bytes");
    try {
      const registry = await ethers.getContractAt("PlayerRegistry", addr);
      const total = await registry.totalPlayers();
      console.log("  totalPlayers:", total.toString());
    } catch (e: any) {
      console.log("  totalPlayers call failed:", e.message?.slice(0, 80));
    }
  }
}

main().catch(console.error);
