import { network } from "hardhat";
import addresses from "../deployments/addresses.json";

const USDC = "0x3600000000000000000000000000000000000000";

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();
  const abi = [
    "function approveToken(address token) external",
    "function isTokenApproved(address token) external view returns (bool)",
  ];
  const escrow     = await ethers.getContractAt(abi, addresses.TransferEscrow, deployer);
  const loanEscrow = await ethers.getContractAt(abi, addresses.LoanEscrow, deployer);

  await (await escrow.approveToken(USDC)).wait();
  console.log(`✅ USDC whitelisted on TransferEscrow`);
  await (await loanEscrow.approveToken(USDC)).wait();
  console.log(`✅ USDC whitelisted on LoanEscrow`);

  console.log(`TransferEscrow USDC: ${await escrow.isTokenApproved(USDC)}`);
  console.log(`LoanEscrow USDC    : ${await loanEscrow.isTokenApproved(USDC)}`);
}

main().catch(err => { console.error(err); process.exit(1); });
