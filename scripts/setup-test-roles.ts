import { network } from "hardhat";
import addresses from "../deployments/addresses.json";

// I grant CLUB_ROLE to the deployer wallet for testing
const TEST_WALLET = "0x13E569C96c7F884443d0c3Ac5019D020dE32bFb3";

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();

  const abi = [
    "function grantRole(bytes32 role, address account) external",
    "function hasRole(bytes32 role, address account) external view returns (bool)",
    "function CLUB_ROLE() external view returns (bytes32)",
    "function LEAGUE_ROLE() external view returns (bytes32)",
  ];

  const registry   = await ethers.getContractAt(abi, addresses.PlayerRegistry, deployer);
  const escrow     = await ethers.getContractAt(abi, addresses.TransferEscrow, deployer);
  const loanEscrow = await ethers.getContractAt(abi, addresses.LoanEscrow, deployer);

  const CLUB_ROLE   = await registry.CLUB_ROLE();
  const LEAGUE_ROLE = await escrow.LEAGUE_ROLE();

  console.log("Granting CLUB_ROLE...");
  await (await registry.grantRole(CLUB_ROLE, TEST_WALLET)).wait();
  await (await escrow.grantRole(CLUB_ROLE, TEST_WALLET)).wait();
  await (await loanEscrow.grantRole(CLUB_ROLE, TEST_WALLET)).wait();
  console.log("✅ CLUB_ROLE granted on PlayerRegistry, TransferEscrow, LoanEscrow");

  console.log("Granting LEAGUE_ROLE...");
  await (await escrow.grantRole(LEAGUE_ROLE, TEST_WALLET)).wait();
  await (await loanEscrow.grantRole(LEAGUE_ROLE, TEST_WALLET)).wait();
  console.log("✅ LEAGUE_ROLE granted on TransferEscrow, LoanEscrow");

  console.log("\nVerification:");
  console.log(`CLUB_ROLE   — Registry: ${await registry.hasRole(CLUB_ROLE, TEST_WALLET)} | Escrow: ${await escrow.hasRole(CLUB_ROLE, TEST_WALLET)} | LoanEscrow: ${await loanEscrow.hasRole(CLUB_ROLE, TEST_WALLET)}`);
  console.log(`LEAGUE_ROLE — Escrow: ${await escrow.hasRole(LEAGUE_ROLE, TEST_WALLET)} | LoanEscrow: ${await loanEscrow.hasRole(LEAGUE_ROLE, TEST_WALLET)}`);
}

main().catch(err => { console.error(err); process.exit(1); });
