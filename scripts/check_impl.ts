import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  const PROXY = "0x1bA3D6557dA3A6a861b2D27596c3c22A75c6c535";

  // EIP-1967 implementation slot
  const IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
  const raw = await ethers.provider.getStorage(PROXY, IMPL_SLOT);
  const impl = "0x" + raw.slice(26);
  console.log("Current implementation:", impl);
  console.log("Expected:             ", "0x1280076f744a52C7dD153d48A2673EbE2C14de2b");
  console.log("Match:", impl.toLowerCase() === "0x1280076f744a52c7dd153d48a2673ebe2c14de2b");

  // Check getBidCount and bidders directly
  const escrow = await ethers.getContractAt("TransferEscrow", PROXY);
  const count = await escrow.getBidCount(1);
  console.log("\ngetBidCount(1):", count.toString());
}

main().catch(console.error);
