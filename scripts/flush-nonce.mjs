import { ethers } from "ethers";
import { config } from "dotenv";
config();

const provider = new ethers.JsonRpcProvider(process.env.ARC_RPC_URL);
const signer   = new ethers.Wallet(process.env.DEPLOYER_PRIVATE_KEY, provider);

const nonce    = await provider.getTransactionCount(signer.address, "latest");
const feeData  = await provider.getFeeData();
const network  = await provider.getNetwork();

// I send a 0-value self-transfer with 2x gas price to replace any stuck tx at this nonce
const tx = await signer.sendTransaction({
  to:       signer.address,
  value:    0n,
  gasLimit: 21_000n,
  gasPrice: feeData.gasPrice * 2n,
  nonce:    nonce,
  chainId:  network.chainId,
});

console.log("Flush tx sent:", tx.hash);
const receipt = await tx.wait();
console.log("Mined in block:", receipt.blockNumber);
console.log("Nonce flushed. Ready to deploy.");
