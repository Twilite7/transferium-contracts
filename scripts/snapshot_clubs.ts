import { network } from "hardhat";
import * as fs from "fs";

async function main() {
  const { ethers } = await network.connect();
  ethers.provider.pollingInterval = 15000;

  const REGISTRY = "0x21962C5548aeD0Ca83c8a1Bf051FE221CB9De4f9";
  const DEPLOY_BLOCK = 50121685;
  const CHUNK = 9000;

  const registry = await ethers.getContractAt("PlayerRegistry", REGISTRY);
  const CLUB_ROLE = await registry.CLUB_ROLE();
  const roleGrantedTopic = ethers.id("RoleGranted(bytes32,address,address)");
  const roleRevokedTopic = ethers.id("RoleRevoked(bytes32,address,address)");
  const paddedRole = ethers.zeroPadValue(CLUB_ROLE, 32);

  const toBlock = await ethers.provider.getBlockNumber();
  const active = new Set<string>();
  const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

  console.log(`Scanning blocks ${DEPLOY_BLOCK} to ${toBlock} (${Math.ceil((toBlock - DEPLOY_BLOCK) / CHUNK)} chunks)...`);

  for (let from = DEPLOY_BLOCK; from <= toBlock; from += CHUNK) {
    const to = Math.min(from + CHUNK - 1, toBlock);
    let attempt = 0;
    while (true) {
      try {
        const [granted, revoked] = await Promise.all([
          ethers.provider.getLogs({ address: REGISTRY, topics: [roleGrantedTopic, paddedRole], fromBlock: from, toBlock: to }),
          ethers.provider.getLogs({ address: REGISTRY, topics: [roleRevokedTopic, paddedRole], fromBlock: from, toBlock: to }),
        ]);
        const decode = (log: any) => ("0x" + log.topics[2].slice(-40)).toLowerCase();
        granted.forEach((log: any) => active.add(decode(log)));
        revoked.forEach((log: any) => active.delete(decode(log)));
        break;
      } catch (e: any) {
        attempt++;
        if (attempt > 6) throw e;
        console.log(`  retry ${attempt} at block ${from}...`);
        await sleep(3000 * attempt);
      }
    }
    if ((from - DEPLOY_BLOCK) / CHUNK % 10 === 0) {
      console.log(`  ...at block ${from} (${active.size} active clubs so far)`);
    }
    if (from + CHUNK <= toBlock) await sleep(2500);
  }

  console.log(`\nFound ${active.size} active clubs. Fetching names/player counts...`);

  const clubs = await Promise.all(
    Array.from(active).map(async (addr) => {
      const name = await registry.getClubName(addr).catch(() => "");
      const playerIds = await registry.getClubPlayers(addr).catch(() => []);
      return { address: addr, name: name || "Unnamed Club", players: playerIds.length };
    })
  );
  clubs.sort((a, b) => b.players - a.players);

  const snapshot = { asOfBlock: toBlock, generatedAt: new Date().toISOString(), clubs };
  const outPath = "/home/kali/transferium-frontend/src/data/clubs_snapshot.json";
  fs.mkdirSync("/home/kali/transferium-frontend/src/data", { recursive: true });
  fs.writeFileSync(outPath, JSON.stringify(snapshot, null, 2));

  console.log(`\n✅ Snapshot written to ${outPath}`);
  console.log(`   asOfBlock: ${toBlock}, clubs: ${clubs.length}`);
}

main().catch(console.error);
