import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  ethers.provider.pollingInterval = 15000;

  const registry = await ethers.getContractAt(
    "PlayerRegistry",
    "0xD79b972d68989f5F98b76a6bbCFFb4Cf0D79D19d"
  );

  const player = await registry.getPlayer(2);
  console.log("Player 2:", player);

  const currentBlock = await ethers.provider.getBlockNumber();
  const fromBlock = Math.max(0, currentBlock - 2000);
  const filter = registry.filters.PlayerRegistered();
  const events = await registry.queryFilter(filter, fromBlock, currentBlock);
  const match = events.find((e: any) => e.args?.playerId?.toString() === "2");
  if (match) {
    console.log("Registered in tx:", match.transactionHash);
    const tx = await ethers.provider.getTransaction(match.transactionHash);
    console.log("From address:", tx?.from);
    const block = await ethers.provider.getBlock(match.blockNumber);
    console.log("Block time:", block ? new Date(Number(block.timestamp) * 1000).toISOString() : "unknown");
  } else {
    console.log("No PlayerRegistered event found for playerId 2 in recent range");
  }
}

main().catch(console.error);
