import { network } from "hardhat";
import { writeFileSync } from "fs";

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();

  console.log("─────────────────────────────────────────");
  console.log("Transferium Protocol — Deployment v2");
  console.log("─────────────────────────────────────────");
  console.log(`Deployer : ${deployer.address}`);
  console.log(`Network  : ${network.name}`);
  console.log(`Chain ID : ${(await ethers.provider.getNetwork()).chainId}`);
  console.log("─────────────────────────────────────────\n");

  const GAS = { gasLimit: 10_000_000n };

  // ── 1. PlayerRegistry ──────────────────────────────────────────────────────
  console.log("Deploying PlayerRegistry...");
  const PlayerRegistry = await ethers.getContractFactory("PlayerRegistry");
  const registry = await PlayerRegistry.deploy(0n, 0n, GAS);
  await registry.waitForDeployment();
  const registryAddress = await registry.getAddress();
  console.log(`✅ PlayerRegistry  : ${registryAddress}`);

  // ── 2. TransferWindow ──────────────────────────────────────────────────────
  console.log("Deploying TransferWindow...");
  const TransferWindow = await ethers.getContractFactory("TransferWindow");
  const transferWindow = await TransferWindow.deploy(GAS);
  await transferWindow.waitForDeployment();
  const transferWindowAddress = await transferWindow.getAddress();
  console.log(`✅ TransferWindow  : ${transferWindowAddress}`);

  // ── 3. TransferEscrow ──────────────────────────────────────────────────────
  console.log("Deploying TransferEscrow...");
  const TransferEscrow = await ethers.getContractFactory("TransferEscrow");
  const escrow = await TransferEscrow.deploy(registryAddress, transferWindowAddress, GAS);
  await escrow.waitForDeployment();
  const escrowAddress = await escrow.getAddress();
  console.log(`✅ TransferEscrow  : ${escrowAddress}`);

  // ── 4. LoanEscrow ──────────────────────────────────────────────────────────
  console.log("Deploying LoanEscrow...");
  const LoanEscrow = await ethers.getContractFactory("LoanEscrow");
  const loanEscrow = await LoanEscrow.deploy(registryAddress, transferWindowAddress, GAS);
  await loanEscrow.waitForDeployment();
  const loanEscrowAddress = await loanEscrow.getAddress();
  console.log(`✅ LoanEscrow      : ${loanEscrowAddress}`);

  // ── Role grants ────────────────────────────────────────────────────────────
  console.log("\nGranting roles...");
  const ESCROW_ROLE = await registry.ESCROW_ROLE();

  let tx = await registry.grantRole(ESCROW_ROLE, escrowAddress, GAS);
  await tx.wait();
  console.log(`✅ ESCROW_ROLE → TransferEscrow`);

  tx = await registry.grantRole(ESCROW_ROLE, loanEscrowAddress, GAS);
  await tx.wait();
  console.log(`✅ ESCROW_ROLE → LoanEscrow`);

  // ── Payment token whitelist ────────────────────────────────────────────────
  const usdcAddress = process.env.USDC_ADDRESS;
  const eurcAddress = process.env.EURC_ADDRESS;

  if (eurcAddress) {
    console.log("\nWhitelisting EURC...");
    tx = await escrow.approveToken(eurcAddress, GAS);
    await tx.wait();
    console.log(`✅ TransferEscrow EURC: ${eurcAddress}`);
    tx = await loanEscrow.approveToken(eurcAddress, GAS);
    await tx.wait();
    console.log(`✅ LoanEscrow EURC    : ${eurcAddress}`);
  }

  if (usdcAddress) {
    console.log("\nWhitelisting USDC...");
    tx = await escrow.approveToken(usdcAddress, GAS);
    await tx.wait();
    console.log(`✅ TransferEscrow USDC: ${usdcAddress}`);
    tx = await loanEscrow.approveToken(usdcAddress, GAS);
    await tx.wait();
    console.log(`✅ LoanEscrow USDC    : ${usdcAddress}`);
  }

  // ── Write addresses ────────────────────────────────────────────────────────
  const addresses = {
    network:         network.name,
    chainId:         (await ethers.provider.getNetwork()).chainId.toString(),
    deployer:        deployer.address,
    deployedAt:      new Date().toISOString(),
    PlayerRegistry:  registryAddress,
    TransferWindow:  transferWindowAddress,
    TransferEscrow:  escrowAddress,
    LoanEscrow:      loanEscrowAddress,
    usdcAddress:     usdcAddress ?? "NOT_SET",
    eurcAddress:     eurcAddress ?? "NOT_SET",
  };

  const { mkdirSync } = await import("fs");
  try { mkdirSync("deployments"); } catch {}

  writeFileSync("deployments/addresses.json", JSON.stringify(addresses, null, 2));

  console.log("\n─────────────────────────────────────────");
  console.log("Deployment complete");
  console.log("Addresses written to deployments/addresses.json");
  console.log("─────────────────────────────────────────");
  console.log("\n⚠️  NEXT STEPS:");
  console.log("  1. Grant CLUB_ROLE on all three contracts to club wallets");
  console.log("  2. Grant REGISTRAR_ROLE on PlayerRegistry to league authority");
  console.log("  3. Grant LEAGUE_ROLE on TransferEscrow and LoanEscrow to league authority");
  console.log("  4. Schedule transfer window via TransferWindow.scheduleWindow()");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
