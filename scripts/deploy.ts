import { network } from "hardhat";
import { writeFileSync } from "fs";

/**
 * Transferium Protocol — Deploy Script
 *
 * Deployment order:
 * 1. PlayerRegistry
 * 2. TransferWindow
 * 3. TransferEscrow (requires PlayerRegistry + TransferWindow)
 * 4. LoanEscrow     (requires PlayerRegistry + TransferWindow)
 *
 * Post-deployment role grants:
 * - ESCROW_ROLE on PlayerRegistry → TransferEscrow and LoanEscrow
 *
 * I write all deployed addresses to deployments/addresses.json
 * for frontend and script consumption.
 */

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();

  console.log("─────────────────────────────────────────");
  console.log("Transferium Protocol — Deployment");
  console.log("─────────────────────────────────────────");
  console.log(`Deployer : ${deployer.address}`);
  console.log(`Network  : ${network.name}`);
  console.log(`Chain ID : ${(await ethers.provider.getNetwork()).chainId}`);
  console.log("─────────────────────────────────────────\n");

  // ── 1. PlayerRegistry ──────────────────────────────────────────────────────
  console.log("Deploying PlayerRegistry...");

  // I set fees to 0 for testnet — adjust for mainnet
  const registrationFee = ethers.parseEther("0");
  const listingFee      = ethers.parseEther("0");

  const PlayerRegistry = await ethers.getContractFactory("PlayerRegistry");
  const registry = await PlayerRegistry.deploy(registrationFee, listingFee);
  await registry.waitForDeployment();
  const registryAddress = await registry.getAddress();
  console.log(`✅ PlayerRegistry  : ${registryAddress}`);

  // ── 2. TransferWindow ──────────────────────────────────────────────────────
  console.log("Deploying TransferWindow...");

  const TransferWindow = await ethers.getContractFactory("TransferWindow");
  const transferWindow = await TransferWindow.deploy();
  await transferWindow.waitForDeployment();
  const transferWindowAddress = await transferWindow.getAddress();
  console.log(`✅ TransferWindow  : ${transferWindowAddress}`);

  // ── 3. TransferEscrow ──────────────────────────────────────────────────────
  console.log("Deploying TransferEscrow...");

  const TransferEscrow = await ethers.getContractFactory("TransferEscrow");
  const escrow = await TransferEscrow.deploy(registryAddress, transferWindowAddress);
  await escrow.waitForDeployment();
  const escrowAddress = await escrow.getAddress();
  console.log(`✅ TransferEscrow  : ${escrowAddress}`);

  // ── 4. LoanEscrow ──────────────────────────────────────────────────────────
  console.log("Deploying LoanEscrow...");

  const LoanEscrow = await ethers.getContractFactory("LoanEscrow");
  const loanEscrow = await LoanEscrow.deploy(registryAddress, transferWindowAddress);
  await loanEscrow.waitForDeployment();
  const loanEscrowAddress = await loanEscrow.getAddress();
  console.log(`✅ LoanEscrow      : ${loanEscrowAddress}`);

  // ── Role grants ────────────────────────────────────────────────────────────
  console.log("\nGranting roles...");

  const ESCROW_ROLE = await registry.ESCROW_ROLE();

  // I grant ESCROW_ROLE to both escrow contracts on PlayerRegistry
  // This allows them to call transferClubOwnership
  let tx = await registry.grantRole(ESCROW_ROLE, escrowAddress);
  await tx.wait();
  console.log(`✅ ESCROW_ROLE → TransferEscrow`);

  tx = await registry.grantRole(ESCROW_ROLE, loanEscrowAddress);
  await tx.wait();
  console.log(`✅ ESCROW_ROLE → LoanEscrow`);

  // ── Payment token whitelist ────────────────────────────────────────────────
  // I read the USDC address from env — must be set before deploying
  const usdcAddress = process.env.USDC_ADDRESS;

  if (usdcAddress) {
    console.log("\nWhitelisting payment token...");

    tx = await escrow.approveToken(usdcAddress);
    await tx.wait();
    console.log(`✅ TransferEscrow token whitelist: ${usdcAddress}`);

    tx = await loanEscrow.approveToken(usdcAddress);
    await tx.wait();
    console.log(`✅ LoanEscrow token whitelist    : ${usdcAddress}`);
  } else {
    console.log("\n⚠️  USDC_ADDRESS not set in .env — skipping token whitelist");
    console.log("   Run approveToken() manually on both escrow contracts after deployment");
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
  };

  // I create deployments directory if it doesn't exist
  const { mkdirSync } = await import("fs");
  try { mkdirSync("deployments"); } catch {}

  writeFileSync(
    "deployments/addresses.json",
    JSON.stringify(addresses, null, 2)
  );

  console.log("\n─────────────────────────────────────────");
  console.log("Deployment complete");
  console.log("Addresses written to deployments/addresses.json");
  console.log("─────────────────────────────────────────");
  console.log("\n⚠️  NEXT STEPS (manual):");
  console.log("  1. Grant CLUB_ROLE on PlayerRegistry to each club wallet");
  console.log("  2. Grant CLUB_ROLE on TransferEscrow to each club wallet");
  console.log("  3. Grant CLUB_ROLE on LoanEscrow to each club wallet");
  console.log("  4. Grant REGISTRAR_ROLE on PlayerRegistry to league authority wallet");
  console.log("  5. Grant LEAGUE_ROLE on TransferEscrow to league authority wallet");
  console.log("  6. Grant LEAGUE_ROLE on LoanEscrow to league authority wallet");
  console.log("  7. Schedule first transfer window via TransferWindow.scheduleWindow()");
  if (!usdcAddress) {
    console.log("  8. Whitelist payment token via approveToken() on both escrow contracts");
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
