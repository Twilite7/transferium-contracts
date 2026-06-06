import { network } from "hardhat";
async function main() {
  const { ethers } = await network.connect();
  const tip = await ethers.provider.getBlockNumber();
  console.log("Current block:", tip);
  const CHUNK = 9000;
  // PlayerRegistry emits RoleGranted during initialize() — that's the earliest event
  const roleGrantedTopic = ethers.id("RoleGranted(bytes32,address,address)");
  for (let from = tip - 150000; from <= tip; from += CHUNK) {
    const to = Math.min(from + CHUNK - 1, tip);
    const logs = await ethers.provider.getLogs({
      address: "0x52D4fb88747d1A5d5af7FBd700578F9F593Bfb58",
      topics: [roleGrantedTopic],
      fromBlock: from,
      toBlock: to,
    }).catch(() => []);
    if (logs.length > 0) {
      const deployBlock = logs[0].blockNumber - 10;
      console.log("DEPLOY_BLOCK=" + deployBlock);
      return;
    }
  }
  console.log("DEPLOY_BLOCK=0");
}
main().catch(() => console.log("DEPLOY_BLOCK=0"));
