import { ethers } from "ethers";
import { config } from "dotenv";
import { readFileSync } from "fs";
config({ path: '/home/kali/transferium-contracts/.env' });

const addresses = JSON.parse(readFileSync('./deployments/addresses.json', 'utf8'));
const provider  = new ethers.JsonRpcProvider(process.env.ARC_RPC_URL);
const signer    = new ethers.Wallet(process.env.DEPLOYER_PRIVATE_KEY, provider);
const USDC      = process.env.USDC_ADDRESS;

const abi = ["function approveToken(address token) external"];

for (const [name, addr] of [["TransferEscrow", addresses.TransferEscrow], ["LoanEscrow", addresses.LoanEscrow]]) {
  const contract = new ethers.Contract(addr, abi, signer);
  const tx = await contract.approveToken(USDC, { gasLimit: 200_000n });
  await tx.wait();
  console.log(`✅ USDC whitelisted on ${name}`);
}
