import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  // ── Token addresses on ARC testnet ────────────────────────────────────────
  const EURC_ADDRESS = "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a";

  // ── Proxy factory ─────────────────────────────────────────────────────────
  const Proxy = await ethers.getContractFactory("TransferiumProxy");

  // ── 1. FeeLib (external library — linked into DealEscrow) ─────────────────
  const FeeLibF = await ethers.getContractFactory("FeeLib");
  const feeLib  = await FeeLibF.deploy();
  await feeLib.waitForDeployment();
  console.log("FeeLib:                 ", await feeLib.getAddress());

  // ── 2. AddressRegistry ────────────────────────────────────────────────────
  const AddressRegistryF = await ethers.getContractFactory("AddressRegistry");
  const addressReg       = await AddressRegistryF.deploy(deployer.address);
  await addressReg.waitForDeployment();
  console.log("AddressRegistry:        ", await addressReg.getAddress());

  // ── 3. PlayerRegistry (UUPS proxy) ────────────────────────────────────────
  const PRF          = await ethers.getContractFactory("PlayerRegistry");
  const registryImpl = await PRF.deploy();
  await registryImpl.waitForDeployment();
  const registryInit = registryImpl.interface.encodeFunctionData("initialize", [
    EURC_ADDRESS,
    0n,           // registrationFee — set via setRegistrationFee after deploy
    0n,           // listingFee      — set via setListingFee after deploy
    deployer.address, // treasury — replace with multisig before mainnet
  ]);
  const registryProxy = await Proxy.deploy(await registryImpl.getAddress(), registryInit);
  await registryProxy.waitForDeployment();
  const registry = PRF.attach(await registryProxy.getAddress());
  console.log("PlayerRegistry proxy:   ", await registryProxy.getAddress());

  // ── 4. TransferWindow (non-upgradeable) ───────────────────────────────────
  const TWF            = await ethers.getContractFactory("TransferWindow");
  const transferWindow = await TWF.deploy();
  await transferWindow.waitForDeployment();
  console.log("TransferWindow:         ", await transferWindow.getAddress());

  // ── 5. Seed TransferWindow into AddressRegistry ───────────────────────────
  const TRANSFER_WINDOW_KEY = ethers.keccak256(ethers.toUtf8Bytes("TRANSFER_WINDOW"));
  await addressReg.seed(TRANSFER_WINDOW_KEY, await transferWindow.getAddress());
  console.log("TransferWindow seeded into AddressRegistry");

  // ── 6. LoanEscrow (UUPS proxy) ────────────────────────────────────────────
  const LoanEscrowF = await ethers.getContractFactory("LoanEscrow");
  const loanImpl    = await LoanEscrowF.deploy();
  await loanImpl.waitForDeployment();
  const loanInit    = loanImpl.interface.encodeFunctionData("initialize", [
    await registry.getAddress(),
    await addressReg.getAddress(),
    deployer.address, // treasury
    deployer.address, // admin
  ]);
  const loanProxy  = await Proxy.deploy(await loanImpl.getAddress(), loanInit);
  await loanProxy.waitForDeployment();
  const loanEscrow = LoanEscrowF.attach(await loanProxy.getAddress());
  console.log("LoanEscrow proxy:       ", await loanProxy.getAddress());

  // ── 7. DealEscrow (UUPS proxy, linked with FeeLib) ────────────────────────
  const DealEscrowF = await ethers.getContractFactory("DealEscrow", {
    libraries: { FeeLib: await feeLib.getAddress() },
  });
  const dealImpl = await DealEscrowF.deploy();
  await dealImpl.waitForDeployment();
  const dealInit = dealImpl.interface.encodeFunctionData("initialize", [
    await registry.getAddress(),
    await addressReg.getAddress(),
    deployer.address, // treasury
    deployer.address, // admin
  ]);
  const dealProxy  = await Proxy.deploy(await dealImpl.getAddress(), dealInit);
  await dealProxy.waitForDeployment();
  const dealEscrow = DealEscrowF.attach(await dealProxy.getAddress());
  console.log("DealEscrow proxy:       ", await dealProxy.getAddress());

  // ── 8. TransferEscrow (UUPS proxy) ────────────────────────────────────────
  const TransferEscrowF = await ethers.getContractFactory("TransferEscrow");
  const teImpl          = await TransferEscrowF.deploy();
  await teImpl.waitForDeployment();
  const teInit = teImpl.interface.encodeFunctionData("initialize", [
    await registry.getAddress(),
    await addressReg.getAddress(),
    await dealEscrow.getAddress(),
    deployer.address, // treasury
    deployer.address, // admin
  ]);
  const teProxy  = await Proxy.deploy(await teImpl.getAddress(), teInit);
  await teProxy.waitForDeployment();
  const escrow = TransferEscrowF.attach(await teProxy.getAddress());
  console.log("TransferEscrow proxy:   ", await teProxy.getAddress());

  // ── 9. InstallmentEscrow (UUPS proxy) ─────────────────────────────────────
  const InstallmentEscrowF = await ethers.getContractFactory("InstallmentEscrow");
  const instImpl           = await InstallmentEscrowF.deploy();
  await instImpl.waitForDeployment();
  const instInit = instImpl.interface.encodeFunctionData("initialize", [
    await dealEscrow.getAddress(),
    deployer.address, // treasury
    deployer.address, // admin
  ]);
  const instProxy         = await Proxy.deploy(await instImpl.getAddress(), instInit);
  await instProxy.waitForDeployment();
  const installmentEscrow = InstallmentEscrowF.attach(await instProxy.getAddress());
  console.log("InstallmentEscrow proxy:", await instProxy.getAddress());

  // ── 10. SwapEscrow (UUPS proxy) ───────────────────────────────────────────
  const SwapEscrowF = await ethers.getContractFactory("SwapEscrow");
  const swapImpl    = await SwapEscrowF.deploy();
  await swapImpl.waitForDeployment();
  const swapInit = swapImpl.interface.encodeFunctionData("initialize", [
    await registry.getAddress(),
    await addressReg.getAddress(),
    await escrow.getAddress(),
    deployer.address, // treasury
    deployer.address, // admin
  ]);
  const swapProxy  = await Proxy.deploy(await swapImpl.getAddress(), swapInit);
  await swapProxy.waitForDeployment();
  const swapEscrow = SwapEscrowF.attach(await swapProxy.getAddress());
  console.log("SwapEscrow proxy:       ", await swapProxy.getAddress());

  // ── 11. FreeTransferEscrow (UUPS proxy) ───────────────────────────────────
  const FreeTransferF = await ethers.getContractFactory("FreeTransferEscrow");
  const freeImpl      = await FreeTransferF.deploy();
  await freeImpl.waitForDeployment();
  const freeInit = freeImpl.interface.encodeFunctionData("initialize", [
    await registry.getAddress(),
    await addressReg.getAddress(),
    await escrow.getAddress(),
    deployer.address, // treasury
    deployer.address, // admin
  ]);
  const freeProxy  = await Proxy.deploy(await freeImpl.getAddress(), freeInit);
  await freeProxy.waitForDeployment();
  const freeEscrow = FreeTransferF.attach(await freeProxy.getAddress());
  console.log("FreeTransferEscrow proxy:", await freeProxy.getAddress());

  // ── 12. VerificationManager (non-upgradeable) ─────────────────────────────
  const VMF = await ethers.getContractFactory("VerificationManager");
  const vm  = await VMF.deploy(await registry.getAddress(), deployer.address);
  await vm.waitForDeployment();
  console.log("VerificationManager:    ", await vm.getAddress());

  // ── 13. TerminationManager (non-upgradeable) ──────────────────────────────
  const TMF             = await ethers.getContractFactory("TerminationManager");
  const terminationMgr  = await TMF.deploy(await registry.getAddress());
  await terminationMgr.waitForDeployment();
  console.log("TerminationManager:     ", await terminationMgr.getAddress());

  // ── 14. Role wiring ───────────────────────────────────────────────────────
  console.log("\nWiring roles...");

  const ESCROW_ROLE          = await registry.ESCROW_ROLE();
  const VERIFICATION_ROLE    = await registry.VERIFICATION_ROLE();
  const LEAGUE_ROLE_REG      = await registry.LEAGUE_ROLE();
  const TRANSFER_ESCROW_ROLE = await dealEscrow.TRANSFER_ESCROW_ROLE();
  const CLUB_ROLE_LOAN       = await loanEscrow.CLUB_ROLE();
  const CLUB_ROLE_SWAP       = await swapEscrow.CLUB_ROLE();
  const CLUB_ROLE_FREE       = await freeEscrow.CLUB_ROLE();

  // DealEscrow accepts callbacks from TransferEscrow only
  await dealEscrow.grantRole(TRANSFER_ESCROW_ROLE, await escrow.getAddress());

  // ESCROW_ROLE on PlayerRegistry — only contracts that call escrowTransfer or burnPlayer
  // TransferEscrow is intentionally excluded — it only reads PlayerRegistry
  await registry.grantRole(ESCROW_ROLE, await dealEscrow.getAddress());
  await registry.grantRole(ESCROW_ROLE, await loanEscrow.getAddress());
  await registry.grantRole(ESCROW_ROLE, await swapEscrow.getAddress());
  await registry.grantRole(ESCROW_ROLE, await freeEscrow.getAddress());
  await registry.grantRole(ESCROW_ROLE, await terminationMgr.getAddress());

  // VerificationManager is the sole holder of VERIFICATION_ROLE
  await registry.grantRole(VERIFICATION_ROLE, await vm.getAddress());

  // TerminationManager checks playerRegistry.hasRole(LEAGUE_ROLE, msg.sender)
  // Grant LEAGUE_ROLE on PlayerRegistry to deployer so forceTerminate works
  await registry.grantRole(LEAGUE_ROLE_REG, deployer.address);

  // Wire TerminationManager so escrowTransfer calls clearTermination
  await registry.setTerminationManager(await terminationMgr.getAddress());

  console.log("Roles wired.");

  // ── 15. Token whitelisting ────────────────────────────────────────────────
  console.log("\nWhitelisting tokens...");

  // TransferEscrow whitelists for offer creation
  await escrow.approveToken(EURC_ADDRESS);

  // All fund-holding escrows
  await dealEscrow.approveToken(EURC_ADDRESS);
  await loanEscrow.approveToken(EURC_ADDRESS);
  await swapEscrow.approveToken(EURC_ADDRESS);
  await freeEscrow.approveToken(EURC_ADDRESS);

  console.log("EURC whitelisted on all escrow contracts.");

  // ── 16. Summary ───────────────────────────────────────────────────────────
  console.log("\n=== DEPLOYMENT COMPLETE — COPY INTO FRONTEND CONFIG ===");
  console.log(`FEELIB:                  ${await feeLib.getAddress()}`);
  console.log(`ADDRESS_REGISTRY:        ${await addressReg.getAddress()}`);
  console.log(`PLAYER_REGISTRY:         ${await registryProxy.getAddress()}`);
  console.log(`TRANSFER_WINDOW:         ${await transferWindow.getAddress()}`);
  console.log(`LOAN_ESCROW:             ${await loanProxy.getAddress()}`);
  console.log(`DEAL_ESCROW:             ${await dealProxy.getAddress()}`);
  console.log(`TRANSFER_ESCROW:         ${await teProxy.getAddress()}`);
  console.log(`INSTALLMENT_ESCROW:      ${await instProxy.getAddress()}`);
  console.log(`SWAP_ESCROW:             ${await swapProxy.getAddress()}`);
  console.log(`FREE_TRANSFER_ESCROW:    ${await freeProxy.getAddress()}`);
  console.log(`VERIFICATION_MANAGER:    ${await vm.getAddress()}`);
  console.log(`TERMINATION_MANAGER:     ${await terminationMgr.getAddress()}`);
}

main().catch(e => { console.error(e); process.exit(1); });
