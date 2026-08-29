import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  ethers.provider.pollingInterval = 15000;

  const REGISTRY = "0x21962C5548aeD0Ca83c8a1Bf051FE221CB9De4f9";

  // 1. Re-check implementation address
  const implSlot = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bb";
  const implRaw = await ethers.provider.getStorage(REGISTRY, implSlot);
  const implAddr = ethers.getAddress("0x" + implRaw.slice(-40));
  console.log("Current implementation:", implAddr);
  console.log("Expected (our fix):      0x2B523Cb1360d1aE23C486d514fF4018703C539B9");

  // 2. Find the actual transaction that set player 2's wallet — search recent blocks
  const registry = await ethers.getContractAt("PlayerRegistry", REGISTRY);
  const currentBlock = await ethers.provider.getBlockNumber();
  const filter = registry.filters.PlayerWalletSet(2);
  const events = await registry.queryFilter(filter, currentBlock - 2000, currentBlock);
  console.log(`\nFound ${events.length} PlayerWalletSet events for player 2 in last 2000 blocks:`);
  for (const ev of events) {
    const tx = await ethers.provider.getTransaction(ev.transactionHash);
    const block = await ethers.provider.getBlock(ev.blockNumber);
    console.log(`  tx ${ev.transactionHash}`);
    console.log(`    from: ${tx?.from}, block: ${ev.blockNumber}, time: ${block ? new Date(Number(block.timestamp) * 1000).toISOString() : "?"}`);
    console.log(`    wallet set to: ${(ev as any).args?.wallet}`);
  }

  // 3. Re-run the exact simulation from before
  const CLUB = "0xf6ee621fcfcee360bf3bba8707144a58b0028f85";
  const signers = await ethers.getSigners();
  const clubSigner = signers.find((s: any) => s.address.toLowerCase() === CLUB.toLowerCase());
  console.log("\nRe-simulating setPlayerWallet(2, registrar_wallet) as club...");
  try {
    await registry.connect(clubSigner).setPlayerWallet.staticCall(2, "0x14F94f8bf5223C2a8BA90092c0F97dfF834C8Bba");
    console.log("❌ SIMULATION SUCCEEDS NOW — something changed since our last check.");
  } catch (e: any) {
    console.log("✅ Simulation still reverts:", e.reason || e.shortMessage || e.message?.slice(0, 150));
  }
}

main().catch(console.error);
