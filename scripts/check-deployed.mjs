import { ethers } from "ethers";
import { config } from "dotenv";
config();

const provider = new ethers.JsonRpcProvider(process.env.ARC_RPC_URL);

// I check recent transactions from deployer to find any contract deployments
const wallet  = new ethers.Wallet(process.env.DEPLOYER_PRIVATE_KEY, provider);
const block   = await provider.getBlockNumber();
console.log("Current block:", block);
console.log("Deployer     :", wallet.address);

// I check the last few transactions
for (let i = block; i > block - 5; i--) {
  const b = await provider.getBlock(i, true);
  if (!b) continue;
  for (const tx of b.transactions) {
    if (typeof tx === 'object' && tx.from?.toLowerCase() === wallet.address.toLowerCase() && !tx.to) {
      console.log(`\nContract deployed at block ${i}:`);
      console.log(`  Tx hash : ${tx.hash}`);
      const receipt = await provider.getTransactionReceipt(tx.hash);
      console.log(`  Address : ${receipt?.contractAddress}`);
    }
  }
}
