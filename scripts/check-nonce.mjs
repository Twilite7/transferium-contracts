import { ethers } from "ethers";
import { config } from "dotenv";
config();

const provider = new ethers.JsonRpcProvider(process.env.ARC_RPC_URL);
const wallet   = new ethers.Wallet(process.env.DEPLOYER_PRIVATE_KEY, provider);

const [confirmed, pending] = await Promise.all([
  provider.getTransactionCount(wallet.address, "latest"),
  provider.getTransactionCount(wallet.address, "pending"),
]);

console.log("Confirmed nonce:", confirmed);
console.log("Pending nonce  :", pending);
