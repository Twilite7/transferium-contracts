import { network } from "hardhat";
import addresses from "../deployments/addresses.json";

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();

  const WRONG_TOKEN   = "0x13E569C96c7F884443d0c3Ac5019D020dE32bFb3";
  const CORRECT_TOKEN = "0x3600000000000000000000000000000000000000";

  const escrowAbi = [
    "function revokeToken(address token) external",
    "function approveToken(address token) external",
    "function isTokenApproved(address token) external view returns (bool)"
  ];

  const escrow     = await ethers.getContractAt(escrowAbi, addresses.TransferEscrow, deployer);
  const loanEscrow = await ethers.getContractAt(escrowAbi, addresses.LoanEscrow, deployer);

  console.log("Fixing token whitelist on TransferEscrow...");
  let tx = await escrow.revokeToken(WRONG_TOKEN);
  await tx.wait();
  console.log(`✅ Revoked wrong token`);

  tx = await escrow.approveToken(CORRECT_TOKEN);
  await tx.wait();
  console.log(`✅ Approved correct USDC`);

  console.log("Fixing token whitelist on LoanEscrow...");
  tx = await loanEscrow.revokeToken(WRONG_TOKEN);
  await tx.wait();
  console.log(`✅ Revoked wrong token`);

  tx = await loanEscrow.approveToken(CORRECT_TOKEN);
  await tx.wait();
  console.log(`✅ Approved correct USDC`);

  console.log("\nDone. Verifying...");
  console.log(`TransferEscrow USDC approved: ${await escrow.isTokenApproved(CORRECT_TOKEN)}`);
  console.log(`LoanEscrow USDC approved    : ${await loanEscrow.isTokenApproved(CORRECT_TOKEN)}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
