import { network } from "hardhat";
import * as fs from "fs";
import * as path from "path";

const EURC = "0x89B50855Aa3bE2F677cD6303Cec809B5F319D72a";
const USDC = "0x3600000000000000000000000000000000000000";

async function deployProxy(ethers: any, deployer: any, contractName: string, initArgs: any[]) {
  const Factory  = await ethers.getContractFactory(contractName, deployer);
  const impl     = await Factory.deploy();
  await impl.waitForDeployment();

  const Proxy    = await ethers.getContractFactory("TransferiumProxy", deployer);
  const initData = Factory.interface.encodeFunctionData("initialize", initArgs);
  const proxy    = await Proxy.deploy(await impl.getAddress(), initData);
  await proxy.waitForDeployment();

  const addr = await proxy.getAddress();
  console.log(`  ${contractName}: ${addr}`);
  return addr;
}

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();
  const admin      = deployer.address;

  console.log("Deployer:", admin);
  console.log("─".repeat(60));

  // ── 1. AddressRegistry ─────────────────────────────────────────────────────
  console.log("\n[1] AddressRegistry");
  const RegistryFactory = await ethers.getContractFactory("AddressRegistry", deployer);
  const addressRegistry = await RegistryFactory.deploy(admin);
  await addressRegistry.waitForDeployment();
  const addressRegistryAddr = await addressRegistry.getAddress();
  console.log(`  AddressRegistry: ${addressRegistryAddr}`);

  // ── 2. PlayerRegistry ──────────────────────────────────────────────────────
  console.log("\n[2] PlayerRegistry");
  const PRFactory      = await ethers.getContractFactory("PlayerRegistry", deployer);
  const REG_FEE        = 500_000n;
  const LIST_FEE       = 0n;
  const playerRegistry = await PRFactory.deploy(REG_FEE, LIST_FEE);
  await playerRegistry.waitForDeployment();
  const playerRegistryAddr = await playerRegistry.getAddress();
  console.log(`  PlayerRegistry: ${playerRegistryAddr}`);

  // ── 3. TransferWindow ──────────────────────────────────────────────────────
  console.log("\n[3] TransferWindow");
  const TWFactory      = await ethers.getContractFactory("TransferWindow", deployer);
  const transferWindow = await TWFactory.deploy();
  await transferWindow.waitForDeployment();
  const transferWindowAddr = await transferWindow.getAddress();
  console.log(`  TransferWindow: ${transferWindowAddr}`);

  // ── 4. Seed AddressRegistry ────────────────────────────────────────────────
  console.log("\n[4] Seeding AddressRegistry");
  const TRANSFER_WINDOW_KEY    = ethers.keccak256(ethers.toUtf8Bytes("TRANSFER_WINDOW"));
  const INSTALLMENT_ESCROW_KEY = ethers.keccak256(ethers.toUtf8Bytes("INSTALLMENT_ESCROW"));
  const FEE_RECIPIENT_KEY      = ethers.keccak256(ethers.toUtf8Bytes("FEE_RECIPIENT"));
  const EURC_TOKEN_KEY         = ethers.keccak256(ethers.toUtf8Bytes("EURC_TOKEN"));
  const USDC_TOKEN_KEY         = ethers.keccak256(ethers.toUtf8Bytes("USDC_TOKEN"));

  await (await addressRegistry.seed(TRANSFER_WINDOW_KEY, transferWindowAddr)).wait();
  await (await addressRegistry.seed(FEE_RECIPIENT_KEY,   admin)).wait();
  await (await addressRegistry.seed(EURC_TOKEN_KEY,      EURC)).wait();
  await (await addressRegistry.seed(USDC_TOKEN_KEY,      USDC)).wait();
  console.log("  TransferWindow, FeeRecipient, EURC, USDC seeded");

  // ── 5. FeeLib ──────────────────────────────────────────────────────────────
  console.log("\n[5] FeeLib");
  const FeeLibFactory = await ethers.getContractFactory("FeeLib", deployer);
  const feeLib        = await FeeLibFactory.deploy();
  await feeLib.waitForDeployment();
  const feeLibAddr    = await feeLib.getAddress();
  console.log(`  FeeLib: ${feeLibAddr}`);

  // ── 6. Escrow contracts ────────────────────────────────────────────────────
  console.log("\n[6] Escrow contracts");

  // DealEscrow (needs FeeLib linked)
  const DealEscrowFact = await ethers.getContractFactory("DealEscrow", {
    signer: deployer, libraries: { FeeLib: feeLibAddr },
  });
  const dealImpl = await DealEscrowFact.deploy();
  await dealImpl.waitForDeployment();
  const dProxy = await (await ethers.getContractFactory("TransferiumProxy", deployer))
    .deploy(
      await dealImpl.getAddress(),
      DealEscrowFact.interface.encodeFunctionData("initialize", [
        playerRegistryAddr, addressRegistryAddr, admin, admin,
      ])
    );
  await dProxy.waitForDeployment();
  const dealEscrowAddr = await dProxy.getAddress();
  console.log(`  DealEscrow: ${dealEscrowAddr}`);

  const transferEscrowAddr = await deployProxy(ethers, deployer, "TransferEscrow", [
    playerRegistryAddr, addressRegistryAddr, dealEscrowAddr, admin, admin,
  ]);

  const releaseEscrowAddr = await deployProxy(ethers, deployer, "ReleaseEscrow", [
    playerRegistryAddr, addressRegistryAddr, transferEscrowAddr, admin, admin,
  ]);

  const swapEscrowAddr = await deployProxy(ethers, deployer, "SwapEscrow", [
    playerRegistryAddr, addressRegistryAddr, transferEscrowAddr, admin, admin,
  ]);

  const freeTransferEscrowAddr = await deployProxy(ethers, deployer, "FreeTransferEscrow", [
    playerRegistryAddr, addressRegistryAddr, transferEscrowAddr, admin, admin,
  ]);

  // ── 7. Non-upgradeable escrows ─────────────────────────────────────────────
  console.log("\n[7] Non-upgradeable escrows");

  const LoanFactory  = await ethers.getContractFactory("LoanEscrow", deployer);
  const loanEscrow   = await LoanFactory.deploy(playerRegistryAddr, addressRegistryAddr);
  await loanEscrow.waitForDeployment();
  const loanEscrowAddr = await loanEscrow.getAddress();
  console.log(`  LoanEscrow: ${loanEscrowAddr}`);

  const InstFactory       = await ethers.getContractFactory("InstallmentEscrow", deployer);
  const installmentEscrow = await InstFactory.deploy(dealEscrowAddr, admin, 50n);
  await installmentEscrow.waitForDeployment();
  const installmentEscrowAddr = await installmentEscrow.getAddress();
  console.log(`  InstallmentEscrow: ${installmentEscrowAddr}`);

  // ── 8. VerificationManager + TerminationManager ────────────────────────────
  console.log("\n[8] VerificationManager + TerminationManager");

  const VMFactory         = await ethers.getContractFactory("VerificationManager", deployer);
  const verificationMgr   = await VMFactory.deploy(playerRegistryAddr, admin);
  await verificationMgr.waitForDeployment();
  const verificationMgrAddr = await verificationMgr.getAddress();
  console.log(`  VerificationManager: ${verificationMgrAddr}`);

  const TMFactory        = await ethers.getContractFactory("TerminationManager", deployer);
  const terminationMgr   = await TMFactory.deploy(playerRegistryAddr);
  await terminationMgr.waitForDeployment();
  const terminationMgrAddr = await terminationMgr.getAddress();
  console.log(`  TerminationManager: ${terminationMgrAddr}`);

  // ── 9. Seed InstallmentEscrow into AddressRegistry ────────────────────────
  console.log("\n[9] Seeding InstallmentEscrow");
  await (await addressRegistry.seed(INSTALLMENT_ESCROW_KEY, installmentEscrowAddr)).wait();
  console.log("  InstallmentEscrow seeded");

  // ── 10. Grant roles ────────────────────────────────────────────────────────
  console.log("\n[10] Granting roles");

  const pr               = await ethers.getContractAt("PlayerRegistry", playerRegistryAddr, deployer);
  const ESCROW_ROLE       = await pr.ESCROW_ROLE();
  const VERIFICATION_ROLE = await pr.VERIFICATION_ROLE();

  // ESCROW_ROLE on PlayerRegistry → all escrow contracts + TerminationManager
  for (const [name, addr] of [
    ["TransferEscrow",     transferEscrowAddr],
    ["DealEscrow",         dealEscrowAddr],
    ["LoanEscrow",         loanEscrowAddr],
    ["ReleaseEscrow",      releaseEscrowAddr],
    ["SwapEscrow",         swapEscrowAddr],
    ["FreeTransferEscrow", freeTransferEscrowAddr],
    ["TerminationManager", terminationMgrAddr],
  ]) {
    await (await pr.grantRole(ESCROW_ROLE, addr)).wait();
    console.log(`  ESCROW_ROLE → ${name}`);
  }

  // VERIFICATION_ROLE on PlayerRegistry → VerificationManager
  await (await pr.grantRole(VERIFICATION_ROLE, verificationMgrAddr)).wait();
  console.log(`  VERIFICATION_ROLE → VerificationManager`);

  // TRANSFER_ESCROW_ROLE on DealEscrow → TransferEscrow + InstallmentEscrow
  const de                   = await ethers.getContractAt("DealEscrow", dealEscrowAddr, deployer);
  const TRANSFER_ESCROW_ROLE = await de.TRANSFER_ESCROW_ROLE();
  await (await de.grantRole(TRANSFER_ESCROW_ROLE, transferEscrowAddr)).wait();
  await (await de.grantRole(TRANSFER_ESCROW_ROLE, installmentEscrowAddr)).wait();
  console.log("  TRANSFER_ESCROW_ROLE → TransferEscrow, InstallmentEscrow");

  // Wire TerminationManager into PlayerRegistry
  await (await pr.setTerminationManager(terminationMgrAddr)).wait();
  console.log("  TerminationManager set on PlayerRegistry");

  // ── 11. Approve tokens on all escrow contracts ─────────────────────────────
  console.log("\n[11] Approving tokens");
  for (const [name, addr] of [
    ["TransferEscrow",     transferEscrowAddr],
    ["DealEscrow",         dealEscrowAddr],
    ["LoanEscrow",         loanEscrowAddr],
    ["ReleaseEscrow",      releaseEscrowAddr],
    ["SwapEscrow",         swapEscrowAddr],
    ["FreeTransferEscrow", freeTransferEscrowAddr],
  ]) {
    const c = await ethers.getContractAt(name, addr, deployer);
    await (await c.approveToken(EURC)).wait();
    await (await c.approveToken(USDC)).wait();
    console.log(`  EURC + USDC approved on ${name}`);
  }

  // ── 12. Write addresses.json ───────────────────────────────────────────────
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
    eurcAddress:         EURC,
    usdcAddress:         USDC,
  };

  const outPath = "/home/kali/transferium-contracts/deployments/addresses.json";
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, JSON.stringify(addresses, null, 2));

  console.log("\n" + "─".repeat(60));
  console.log("Deployment complete. addresses.json updated.");
  console.log(JSON.stringify(addresses, null, 2));
}

main().catch(console.error);
