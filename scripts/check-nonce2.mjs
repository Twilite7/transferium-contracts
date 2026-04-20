import { ethers } from "ethers";
import { config } from "dotenv";
config();

const provider = new ethers.JsonRpcProvider(process.env.ARC_RPC_URL);
const wallet   = new ethers.Wallet(process.env.DEPLOYER_PRIVATE_KEY, provider);

const [confirmed, pending] = await Promise.all([
  provider.getTransactionCount(wallet.address, "latest"),
  provider.getTransactionCount(wallet.address, "pending"),
]);

console.log("Address        :", wallet.address);
console.log("Confirmed nonce:", confirmed);
console.log("Pending nonce  :", pending);
console.log("Stuck txs      :", pending - confirmed);

// I check if the exact tx from the error is still pending
const txHash = "0x02f93f3683";
const receipt = await provider.getTransactionReceipt(
  "0xec9947d68807a7e85d24a7437520f59bd2ef7c5a313a445f9772c675f530218d"
);
console.log("Previous tx receipt:", receipt ? `mined in block ${receipt.blockNumber}` : "not found / still pending");
