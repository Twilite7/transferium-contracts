import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  ethers.provider.pollingInterval = 15000;

  const REGISTRY = "0x21962C5548aeD0Ca83c8a1Bf051FE221CB9De4f9";
  const TX_HASH = "0x0d441ca04b38ff3e1b89b8c11a8c3c8915697641241fd7743819c119e27f5dfe";

  const registry = await ethers.getContractAt("PlayerRegistry", REGISTRY);
  const receipt = await ethers.provider.getTransactionReceipt(TX_HASH);
  console.log("Transaction status:", receipt?.status, "(1 = success, 0 = reverted)");
  console.log("Block:", receipt?.blockNumber);
  console.log("From:", receipt?.from);
  console.log("To:", receipt?.to);

  const tx = await ethers.provider.getTransaction(TX_HASH);
  console.log("\nRaw calldata:", tx?.data);

  // Decode the calldata directly against the current ABI
  try {
    const decoded = registry.interface.parseTransaction({ data: tx!.data });
    console.log("\nDecoded function call:", decoded?.name);
    console.log("Decoded args:", decoded?.args);
  } catch (e: any) {
    console.log("\nCould not decode calldata:", e.message?.slice(0, 150));
  }

  console.log("\nAll logs in this transaction:");
  for (const log of receipt?.logs || []) {
    try {
      const parsed = registry.interface.parseLog(log);
      console.log(`  ${parsed?.name}:`, parsed?.args);
    } catch {
      console.log("  (unparseable log)", log.topics[0]);
    }
  }
}

main().catch(console.error);
