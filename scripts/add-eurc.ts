import { network } from "hardhat";
import addresses from "../deployments/addresses.json";

const EURC_ADDRESS = "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a";

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();

  const abi = [
    "function approveToken(address token) external",
    "function isTokenApproved(address token) external view returns (bool)"
  ];

  const escrow     = await ethers.getContractAt(abi, addresses.TransferEscrow, deployer);
  const loanEscrow = await ethers.getContractAt(abi, addresses.LoanEscrow, deployer);

  console.log("Whitelisting EURC on TransferEscrow...");
  await (await escrow.approveToken(EURC_ADDRESS)).wait();
  console.log("Whitelisting EURC on LoanEscrow...");
  await (await loanEscrow.approveToken(EURC_ADDRESS)).wait();

  console.log(`\nTransferEscrow EURC approved: ${await escrow.isTokenApproved(EURC_ADDRESS)}`);
  console.log(`LoanEscrow EURC approved    : ${await loanEscrow.isTokenApproved(EURC_ADDRESS)}`);
}

main().catch(err => { console.error(err); process.exit(1); });
