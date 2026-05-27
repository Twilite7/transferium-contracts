import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const Proxy = await ethers.getContractFactory("TransferiumProxy");

  // 1. FeeLib
  const FeeLibF = await ethers.getContractFactory("FeeLib");
  const feeLib  = await FeeLibF.deploy();
  await feeLib.waitForDeployment();
  console.log("FeeLib:          ", await feeLib.getAddress());

  // 2. PlayerRegistry (non-proxy)
  const PRF      = await ethers.getContractFactory("PlayerRegistry");
  const registry = await PRF.deploy(
    ethers.parseEther("0.01"),
    ethers.parseEther("0.005")
  );
  await registry.waitForDeployment();
  console.log("PlayerRegistry:  ", await registry.getAddress());

  // 3. TransferWindow (non-proxy)
  const TWF    = await ethers.getContractFactory("TransferWindow");
  const window = await TWF.deploy();
  await window.waitForDeployment();
  console.log("TransferWindow:  ", await window.getAddress());

  // 4. LoanEscrow (non-proxy)
  const LEF        = await ethers.getContractFactory("LoanEscrow");
  const loanEscrow = await LEF.deploy(
    await registry.getAddress(),
    await window.getAddress()
  );
  await loanEscrow.waitForDeployment();
  console.log("LoanEscrow:      ", await loanEscrow.getAddress());

  // 5. DealEscrow (UUPS proxy)
  const DEF      = await ethers.getContractFactory("DealEscrow", { libraries: { FeeLib: await feeLib.getAddress() } });
  const dealImpl = await DEF.deploy();
  await dealImpl.waitForDeployment();
  const dealInit = dealImpl.interface.encodeFunctionData("initialize", [
    await registry.getAddress(),
    await window.getAddress(),
    deployer.address,   // treasury — change to multisig before mainnet
    deployer.address,   // admin    — change to multisig before mainnet
  ]);
  const dealProxy = await Proxy.deploy(await dealImpl.getAddress(), dealInit);
  await dealProxy.waitForDeployment();
  const dealEscrow = DEF.attach(await dealProxy.getAddress());
  console.log("DealEscrow proxy:", await dealProxy.getAddress());

  // 6. TransferEscrow (UUPS proxy)
  const TEF    = await ethers.getContractFactory("TransferEscrow");
  const teImpl = await TEF.deploy();
  await teImpl.waitForDeployment();
  const teInit = teImpl.interface.encodeFunctionData("initialize", [
    await registry.getAddress(),
    await window.getAddress(),
    await dealEscrow.getAddress(),
    deployer.address,   // treasury
    deployer.address,   // admin
  ]);
  const teProxy = await Proxy.deploy(await teImpl.getAddress(), teInit);
  await teProxy.waitForDeployment();
  const escrow = TEF.attach(await teProxy.getAddress());
  console.log("TransferEscrow proxy:", await teProxy.getAddress());

  // 7. ReleaseEscrow (UUPS proxy)
  // I deploy after TransferEscrow so we can pass its address into initialize
  const REF         = await ethers.getContractFactory("ReleaseEscrow");
  const releaseImpl = await REF.deploy();
  await releaseImpl.waitForDeployment();
  const releaseInit = releaseImpl.interface.encodeFunctionData("initialize", [
    await registry.getAddress(),
    await window.getAddress(),
    await escrow.getAddress(),   // TransferEscrow — ReleaseEscrow checks it for active offers/deals
    deployer.address,            // treasury
    deployer.address,            // admin
  ]);
  const releaseProxy = await Proxy.deploy(await releaseImpl.getAddress(), releaseInit);
  await releaseProxy.waitForDeployment();
  const releaseEscrow = REF.attach(await releaseProxy.getAddress());
  console.log("ReleaseEscrow proxy:", await releaseProxy.getAddress());

  // 8. Wire roles
  const TRANSFER_ESCROW_ROLE = await dealEscrow.TRANSFER_ESCROW_ROLE();
  const ESCROW_ROLE          = await registry.ESCROW_ROLE();

  // DealEscrow needs TRANSFER_ESCROW_ROLE to accept callbacks from TransferEscrow
  await dealEscrow.grantRole(TRANSFER_ESCROW_ROLE, await escrow.getAddress());

  // All escrow contracts need ESCROW_ROLE to move player NFTs via escrowTransfer
  await registry.grantRole(ESCROW_ROLE, await escrow.getAddress());
  await registry.grantRole(ESCROW_ROLE, await dealEscrow.getAddress());
  await registry.grantRole(ESCROW_ROLE, await loanEscrow.getAddress());
  await registry.grantRole(ESCROW_ROLE, await releaseEscrow.getAddress());

  console.log("Roles wired.");

  // 9. Whitelist EURC and USDC on all escrow contracts that hold tokens
  const EURC = "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a";
  const USDC = "0x3600000000000000000000000000000000000000";

  for (const token of [EURC, USDC]) {
    await dealEscrow.approveToken(token);
    await loanEscrow.approveToken(token);
    await releaseEscrow.approveToken(token);
  }
  console.log("EURC + USDC whitelisted on DealEscrow, LoanEscrow, ReleaseEscrow.");

  console.log("\n--- COPY THESE INTO YOUR FRONTEND ---");
  console.log(`FEELIB:           ${await feeLib.getAddress()}`);
  console.log(`PLAYER_REGISTRY:  ${await registry.getAddress()}`);
  console.log(`TRANSFER_WINDOW:  ${await window.getAddress()}`);
  console.log(`LOAN_ESCROW:      ${await loanEscrow.getAddress()}`);
  console.log(`DEAL_ESCROW:      ${await dealProxy.getAddress()}`);
  console.log(`TRANSFER_ESCROW:  ${await teProxy.getAddress()}`);
  console.log(`RELEASE_ESCROW:   ${await releaseProxy.getAddress()}`);

  // 8. SwapEscrow (UUPS proxy)
  const SwapEscrowF = await ethers.getContractFactory("SwapEscrow");
  const swapImpl    = await SwapEscrowF.deploy();
  await swapImpl.waitForDeployment();
  const swapInit    = swapImpl.interface.encodeFunctionData("initialize", [
    await registry.getAddress(),
    await window.getAddress(),
    await escrow.getAddress(),
    deployer.address,
    deployer.address,
  ]);
  const swapProxy   = await Proxy.deploy(await swapImpl.getAddress(), swapInit);
  await swapProxy.waitForDeployment();
  const swapEscrow  = SwapEscrowF.attach(await swapProxy.getAddress());
  console.log("SwapEscrow proxy:", await swapProxy.getAddress());

  // 9. FreeTransferEscrow (UUPS proxy)
  const FreeTransferF = await ethers.getContractFactory("FreeTransferEscrow");
  const freeImpl      = await FreeTransferF.deploy();
  await freeImpl.waitForDeployment();
  const freeInit      = freeImpl.interface.encodeFunctionData("initialize", [
    await registry.getAddress(),
    await window.getAddress(),
    await escrow.getAddress(),
    deployer.address,
    deployer.address,
  ]);
  const freeProxy     = await Proxy.deploy(await freeImpl.getAddress(), freeInit);
  await freeProxy.waitForDeployment();
  const freeEscrow    = FreeTransferF.attach(await freeProxy.getAddress());
  console.log("FreeTransferEscrow proxy:", await freeProxy.getAddress());

  // 10. Grant ESCROW_ROLE to new contracts
  await registry.grantRole(ESCROW_ROLE, await swapEscrow.getAddress());
  await registry.grantRole(ESCROW_ROLE, await freeEscrow.getAddress());

  // 11. Whitelist tokens on new contracts
  for (const token of [EURC, USDC]) {
    await swapEscrow.approveToken(token);
    await freeEscrow.approveToken(token);
  }
  console.log("Roles and tokens set for SwapEscrow + FreeTransferEscrow.");
  console.log(`SWAP_ESCROW:           ${await swapProxy.getAddress()}`);
  console.log(`FREE_TRANSFER_ESCROW:  ${await freeProxy.getAddress()}`);
}

main().catch(e => { console.error(e); process.exit(1); });
