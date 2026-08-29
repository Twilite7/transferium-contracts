import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  ethers.provider.pollingInterval = 15000;
  const REGISTRY = "0x21962C5548aeD0Ca83c8a1Bf051FE221CB9De4f9";
  const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));

  // Retry the implementation slot read up to 5 times
  const implSlot = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bb";
  for (let i = 0; i < 5; i++) {
    try {
      const implRaw = await ethers.provider.getStorage(REGISTRY, implSlot);
      const implAddr = ethers.getAddress("0x" + implRaw.slice(-40));
      console.log(`Attempt ${i + 1} — implementation:`, implAddr);
      if (implAddr !== ethers.ZeroAddress) break;
    } catch (e: any) {
      console.log(`Attempt ${i + 1} failed:`, e.message?.slice(0, 100));
    }
    await sleep(3000);
  }

  const registry = await ethers.getContractAt("PlayerRegistry", REGISTRY);

  // Does this wallet currently hold REGISTRAR_ROLE right now?
  const REGISTRAR_ROLE = await registry.REGISTRAR_ROLE();
  const wallet = "0x14F94f8bf5223C2a8BA90092c0F97dfF834C8Bba";
  const hasRole = await registry.hasRole(REGISTRAR_ROLE, wallet);
  console.log("\nWallet currently holds REGISTRAR_ROLE:", hasRole);

  // Player 2 current state
  const player = await registry.getPlayer(2);
  console.log("Player 2 wallet:", player.playerWallet);

  // Full RoleGranted/RoleRevoked history for this wallet's REGISTRAR_ROLE, to see if it was
  // revoked and re-granted, or anything unusual, since our remediation a month ago
  const grantedTopic = ethers.id("RoleGranted(bytes32,address,address)");
  const revokedTopic = ethers.id("RoleRevoked(bytes32,address,address)");
  const paddedRole = ethers.zeroPadValue(REGISTRAR_ROLE, 32);
  const paddedWallet = ethers.zeroPadValue(wallet, 32);
  const currentBlock = await ethers.provider.getBlockNumber();
  const granted = await registry.queryFilter(
    registry.filters.RoleGranted(REGISTRAR_ROLE, wallet), currentBlock - 500000, currentBlock
  ).catch((e: any) => { console.log("grant query failed:", e.message?.slice(0,100)); return []; });
  const revoked = await registry.queryFilter(
    registry.filters.RoleRevoked(REGISTRAR_ROLE, wallet), currentBlock - 500000, currentBlock
  ).catch((e: any) => { console.log("revoke query failed:", e.message?.slice(0,100)); return []; });
  console.log(`\nRoleGranted(REGISTRAR_ROLE, this wallet) events: ${granted.length}`);
  for (const g of granted) console.log("  block", g.blockNumber, g.transactionHash);
  console.log(`RoleRevoked(REGISTRAR_ROLE, this wallet) events: ${revoked.length}`);
  for (const r of revoked) console.log("  block", r.blockNumber, r.transactionHash);
}

main().catch(console.error);
