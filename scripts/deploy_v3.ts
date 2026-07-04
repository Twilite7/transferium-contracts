import { network } from "hardhat";
import * as fs from "fs";
import * as path from "path";

const EURC = "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a";
const USDC = "0x3600000000000000000000000000000000000000";

async function deployProxy(
  ethers: any,
  deployer: any,
  contractName: string,
  initArgs: any[],
  libraries: Record<string, string> = {}
): Promise<string> {
  const Factory  = await ethers.getContractFactory(contractName, { signer: deployer, libraries });
  const impl     = await Factory.deploy();
  await impl.waitForDeployment();

  const ProxyFact = await ethers.getContractFactory("TransferiumProxy", deployer);
  const initData  = Factory.interface.encodeFunctionData("initialize", initArgs);
  const proxy     = await ProxyFact.deploy(await impl.getAddress(), initData);
  await proxy.waitForDeployment();

  const addr = await proxy.getAddress();
  console.log(`  ${contractName}: ${addr}  (impl: ${await impl.getAddress()})`);
  return addr;
}

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();
  const admin      = deployer.address;

  console.log("Deployer:", admin);
  console.log("─".repeat(60));

  // ── 1. AddressRegistry (plain — not upgradeable) ───────────────────────────
  console.log("\n[1] AddressRegistry");
  const addressRegistry = await (await ethers.getContractFactory("AddressRegistry", deployer))
    .deploy(admin);
  await addressRegistry.waitForDeployment();
  const addressRegistryAddr = await addressRegistry.getAddress();
  console.log(`  AddressRegistry: ${addressRegistryAddr}`);

  // ── 2. PlayerRegistry (UUPS proxy) ────────────────────────────────────────
  console.log("\n[2] PlayerRegistry");
  const REG_FEE        = 500_000n;   // 0.5 EURC (6 decimals)
  const LIST_FEE       = 0n;
  const BASE_VERIF_FEE = 2_000_000n; // 2 EURC — registrars may charge up to 120% (2.4 EURC max)
  const playerRegistryAddr = await deployProxy(ethers, deployer, "PlayerRegistry", [
    EURC, REG_FEE, LIST_FEE, BASE_VERIF_FEE, admin,
  ]);

  // ── 3. TransferWindow (plain) ──────────────────────────────────────────────
  console.log("\n[3] TransferWindow");
  const transferWindow = await (await ethers.getContractFactory("TransferWindow", deployer))
    .deploy();
  await transferWindow.waitForDeployment();
  const transferWindowAddr = await transferWindow.getAddress();
  console.log(`  TransferWindow: ${transferWindowAddr}`);

  // ── 4. Seed AddressRegistry ────────────────────────────────────────────────
  console.log("\n[4] Seeding AddressRegistry");
  const TRANSFER_WINDOW_KEY    = ethers.keccak256(ethers.toUtf8Bytes("TRANSFER_WINDOW"));
  const FEE_RECIPIENT_KEY      = ethers.keccak256(ethers.toUtf8Bytes("FEE_RECIPIENT"));
  const EURC_TOKEN_KEY         = ethers.keccak256(ethers.toUtf8Bytes("EURC_TOKEN"));
  const USDC_TOKEN_KEY         = ethers.keccak256(ethers.toUtf8Bytes("USDC_TOKEN"));
  const INSTALLMENT_ESCROW_KEY = ethers.keccak256(ethers.toUtf8Bytes("INSTALLMENT_ESCROW"));

  await (await addressRegistry.seed(TRANSFER_WINDOW_KEY, transferWindowAddr)).wait();
  await (await addressRegistry.seed(FEE_RECIPIENT_KEY,   admin)).wait();
  await (await addressRegistry.seed(EURC_TOKEN_KEY,      EURC)).wait();
  await (await addressRegistry.seed(USDC_TOKEN_KEY,      USDC)).wait();
  console.log("  TransferWindow, FeeRecipient, EURC, USDC seeded");

  // ── 5. FeeLib (external library) ──────────────────────────────────────────
  console.log("\n[5] FeeLib");
  const feeLib     = await (await ethers.getContractFactory("FeeLib", deployer)).deploy();
  await feeLib.waitForDeployment();
  const feeLibAddr = await feeLib.getAddress();
  console.log(`  FeeLib: ${feeLibAddr}`);

  // ── 6. DealEscrow (needs FeeLib linked, UUPS proxy) ───────────────────────
  console.log("\n[6] DealEscrow");
  const dealEscrowAddr = await deployProxy(
    ethers, deployer, "DealEscrow",
    [playerRegistryAddr, addressRegistryAddr, admin, admin],
    { FeeLib: feeLibAddr }
  );

  // ── 7. TransferEscrow (UUPS proxy) ────────────────────────────────────────
  console.log("\n[7] TransferEscrow");
  const transferEscrowAddr = await deployProxy(ethers, deployer, "TransferEscrow", [
    playerRegistryAddr, addressRegistryAddr, dealEscrowAddr, admin, admin,
  ]);

  // ── 8. ReleaseEscrow (UUPS proxy) ─────────────────────────────────────────
  console.log("\n[8] ReleaseEscrow");
  const releaseEscrowAddr = await deployProxy(ethers, deployer, "ReleaseEscrow", [
    playerRegistryAddr, addressRegistryAddr, transferEscrowAddr, admin, admin,
  ]);

  // ── 9. SwapEscrow (UUPS proxy) ────────────────────────────────────────────
  console.log("\n[9] SwapEscrow");
  const swapEscrowAddr = await deployProxy(ethers, deployer, "SwapEscrow", [
    playerRegistryAddr, addressRegistryAddr, transferEscrowAddr, admin, admin,
  ]);

  // ── 10. FreeTransferEscrow (UUPS proxy) ───────────────────────────────────
  console.log("\n[10] FreeTransferEscrow");
  const freeTransferEscrowAddr = await deployProxy(ethers, deployer, "FreeTransferEscrow", [
    playerRegistryAddr, addressRegistryAddr, transferEscrowAddr, admin, admin,
  ]);

  // ── 11. LoanEscrow (UUPS proxy) ───────────────────────────────────────────
  console.log("\n[11] LoanEscrow");
  const loanEscrowAddr = await deployProxy(ethers, deployer, "LoanEscrow", [
    playerRegistryAddr, addressRegistryAddr, admin, admin,
  ]);

  // ── 12. InstallmentEscrow (UUPS proxy) ────────────────────────────────────
  console.log("\n[12] InstallmentEscrow");
  const installmentEscrowAddr = await deployProxy(ethers, deployer, "InstallmentEscrow", [
    dealEscrowAddr, admin, admin,
  ]);

  // ── 13. VerificationManager (plain) ───────────────────────────────────────
  console.log("\n[13] VerificationManager");
  const verificationMgr = await (await ethers.getContractFactory("VerificationManager", deployer))
    .deploy(playerRegistryAddr, admin);
  await verificationMgr.waitForDeployment();
  const verificationMgrAddr = await verificationMgr.getAddress();
  console.log(`  VerificationManager: ${verificationMgrAddr}`);

  // ── 14. TerminationManager (plain) ────────────────────────────────────────
  console.log("\n[14] TerminationManager");
  const terminationMgr = await (await ethers.getContractFactory("TerminationManager", deployer))
    .deploy(playerRegistryAddr);
  await terminationMgr.waitForDeployment();
  const terminationMgrAddr = await terminationMgr.getAddress();
  console.log(`  TerminationManager: ${terminationMgrAddr}`);

  // ── 15. CompetingBidManager (plain) ─────────────────────────────────────────
  console.log("\n[15] CompetingBidManager");
  const competingBidMgr = await (await ethers.getContractFactory("CompetingBidManager", deployer))
    .deploy(dealEscrowAddr, admin);
  await competingBidMgr.waitForDeployment();
  const competingBidMgrAddr = await competingBidMgr.getAddress();
  console.log(`  CompetingBidManager: ${competingBidMgrAddr}`);

  // ── 16. Seed InstallmentEscrow into AddressRegistry ───────────────────────
  console.log("\n[16] Seeding InstallmentEscrow");
  await (await addressRegistry.seed(INSTALLMENT_ESCROW_KEY, installmentEscrowAddr)).wait();
  console.log("  InstallmentEscrow seeded");

  // ── 16. Grant roles ────────────────────────────────────────────────────────
  console.log("\n[16] Granting roles");
  const pr = await ethers.getContractAt("PlayerRegistry", playerRegistryAddr, deployer);

  const ESCROW_ROLE       = await pr.ESCROW_ROLE();
  const VERIFICATION_ROLE = await pr.VERIFICATION_ROLE();

  for (const [name, addr] of [
    ["TransferEscrow",     transferEscrowAddr],
    ["DealEscrow",         dealEscrowAddr],
    ["LoanEscrow",         loanEscrowAddr],
    ["ReleaseEscrow",      releaseEscrowAddr],
    ["SwapEscrow",         swapEscrowAddr],
    ["FreeTransferEscrow", freeTransferEscrowAddr],
    ["TerminationManager", terminationMgrAddr],
  ] as const) {
    await (await pr.grantRole(ESCROW_ROLE, addr)).wait();
    console.log(`  ESCROW_ROLE → ${name}`);
  }

  await (await pr.grantRole(VERIFICATION_ROLE, verificationMgrAddr)).wait();
  console.log(`  VERIFICATION_ROLE → VerificationManager`);

  // TRANSFER_ESCROW_ROLE on DealEscrow → TransferEscrow + InstallmentEscrow
  const de = await ethers.getContractAt("DealEscrow", dealEscrowAddr, deployer);
  const TRANSFER_ESCROW_ROLE = await de.TRANSFER_ESCROW_ROLE();
  await (await de.grantRole(TRANSFER_ESCROW_ROLE, transferEscrowAddr)).wait();
  await (await de.grantRole(TRANSFER_ESCROW_ROLE, installmentEscrowAddr)).wait();
  console.log("  TRANSFER_ESCROW_ROLE → TransferEscrow, InstallmentEscrow");
  // COMPETING_BID_MANAGER_ROLE on DealEscrow → CompetingBidManager
  const COMPETING_BID_MANAGER_ROLE = await de.COMPETING_BID_MANAGER_ROLE();
  await (await de.grantRole(COMPETING_BID_MANAGER_ROLE, competingBidMgrAddr)).wait();
  console.log("  COMPETING_BID_MANAGER_ROLE → CompetingBidManager");

  // CLUB_ROLE on TransferEscrow + LoanEscrow is granted per-club via Admin panel.
  // TransferWindow uses its own internal role — no cross-contract grant needed.

  // Wire CompetingBidManager into DealEscrow
  await (await de.setCompetingBidManager(competingBidMgrAddr)).wait();
  console.log("  CompetingBidManager set on DealEscrow");

  // Wire TerminationManager into PlayerRegistry
  await (await pr.setTerminationManager(terminationMgrAddr)).wait();
  console.log("  TerminationManager set on PlayerRegistry");

  // ── 18. Approve tokens on escrow contracts ─────────────────────────────────
  console.log("\n[18] Approving tokens");
  for (const [name, addr] of [
    ["TransferEscrow",     transferEscrowAddr],
    ["DealEscrow",         dealEscrowAddr],
    ["LoanEscrow",         loanEscrowAddr],
    ["ReleaseEscrow",      releaseEscrowAddr],
    ["SwapEscrow",         swapEscrowAddr],
    ["FreeTransferEscrow", freeTransferEscrowAddr],
  ] as const) {
    const c = await ethers.getContractAt(name, addr, deployer);
    try { await (await c.approveToken(EURC)).wait(); } catch {}
    try { await (await c.approveToken(USDC)).wait(); } catch {}
    console.log(`  EURC + USDC → ${name}`);
  }

  // ── 19. Write addresses ────────────────────────────────────────────────────
  const addresses = {
    chainId:             "5042002",
    deployer:            admin,
    deployedAt:          new Date().toISOString(),
    AddressRegistry:     addressRegistryAddr,
    PlayerRegistry:      playerRegistryAddr,
    TransferWindow:      transferWindowAddr,
    FeeLib:              feeLibAddr,
    TransferEscrow:      transferEscrowAddr,
    DealEscrow:          dealEscrowAddr,
    LoanEscrow:          loanEscrowAddr,
    ReleaseEscrow:       releaseEscrowAddr,
    SwapEscrow:          swapEscrowAddr,
    FreeTransferEscrow:  freeTransferEscrowAddr,
    InstallmentEscrow:   installmentEscrowAddr,
    VerificationManager: verificationMgrAddr,
    TerminationManager:  terminationMgrAddr,
    CompetingBidManager: competingBidMgrAddr,
    eurcAddress:         EURC,
    usdcAddress:         USDC,
  };

  const outPath = "/home/kali/transferium-contracts/deployments/addresses.json";
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, JSON.stringify(addresses, null, 2));

  console.log("\n" + "─".repeat(60));
  console.log("✅ Deployment complete");
  console.log("\n=== Paste into frontend contracts.ts ===");
  console.log(`  PlayerRegistry:      '${playerRegistryAddr}',`);
  console.log(`  TransferWindow:      '${transferWindowAddr}',`);
  console.log(`  TransferEscrow:      '${transferEscrowAddr}',`);
  console.log(`  DealEscrow:          '${dealEscrowAddr}',`);
  console.log(`  LoanEscrow:          '${loanEscrowAddr}',`);
  console.log(`  ReleaseEscrow:       '${releaseEscrowAddr}',`);
  console.log(`  SwapEscrow:          '${swapEscrowAddr}',`);
  console.log(`  FreeTransferEscrow:  '${freeTransferEscrowAddr}',`);
  console.log(`  InstallmentEscrow:   '${installmentEscrowAddr}',`);
  console.log(`  AddressRegistry:     '${addressRegistryAddr}',`);
  console.log(`  VerificationManager: '${verificationMgrAddr}',`);
  console.log(`  TerminationManager:  '${terminationMgrAddr}',`);
  console.log(`  CompetingBidManager: '${competingBidMgrAddr}',`);
}

main().catch(console.error);
