import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  const ADDR = "0x21962C5548aeD0Ca83c8a1Bf051FE221CB9De4f9";

  const latest = await ethers.provider.getBlockNumber();
  let lo = 0;
  let hi = latest;

  // Binary search for the first block where code exists at ADDR
  while (lo < hi) {
    const mid = Math.floor((lo + hi) / 2);
    const code = await ethers.provider.getCode(ADDR, mid);
    if (code === "0x") {
      lo = mid + 1;
    } else {
      hi = mid;
    }
    console.log(`checked block ${mid}: ${code === "0x" ? "no code" : "has code"}`);
  }

  console.log("\nFirst block with code at", ADDR, ":", lo);
  const block = await ethers.provider.getBlock(lo);
  console.log("Timestamp:", block ? new Date(Number(block.timestamp) * 1000).toISOString() : "unknown");
}

main().catch(console.error);
