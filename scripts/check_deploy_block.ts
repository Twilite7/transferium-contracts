import { network } from "hardhat";
async function main() {
  const { ethers } = await network.connect();
  const registry = new ethers.Contract(
    "0x5212d6719883a45B4Cc1Fb32Ab04EC1c5ABdb200",
    ["event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender)"],
    ethers.provider
  );
  const tip = await ethers.provider.getBlockNumber();
  console.log("Tip:", tip);
  // Search last 50000 blocks in chunks
  for (let from = tip - 50000; from <= tip; from += 9000) {
    const to = Math.min(from + 8999, tip);
    const events = await registry.queryFilter(registry.filters.RoleGranted(), from, to);
    if (events.length > 0) {
      console.log("First event block:", events[0].blockNumber);
      break;
    }
  }
}
main().catch(console.error);
