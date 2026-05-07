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
  const LEF      = await ethers.getContractFactory("LoanEscrow");
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

  // 7. Wire roles
  const TRANSFER_ESCROW_ROLE = await dealEscrow.TRANSFER_ESCROW_ROLE();
  const ESCROW_ROLE          = await registry.ESCROW_ROLE();
  await dealEscrow.grantRole(TRANSFER_ESCROW_ROLE, await escrow.getAddress());
  await registry.grantRole(ESCROW_ROLE, await escrow.getAddress());
  await registry.grantRole(ESCROW_ROLE, await dealEscrow.getAddress());
  await registry.grantRole(ESCROW_ROLE, await loanEscrow.getAddress());
  console.log("Roles wired.");

  console.log("\n--- COPY THESE INTO YOUR FRONTEND ---");
  console.log(`FEELIB:           ${await feeLib.getAddress()}`);
  console.log(`PLAYER_REGISTRY:  ${await registry.getAddress()}`);
  console.log(`TRANSFER_WINDOW:  ${await window.getAddress()}`);
  console.log(`LOAN_ESCROW:      ${await loanEscrow.getAddress()}`);
  console.log(`DEAL_ESCROW:      ${await dealProxy.getAddress()}`);
  console.log(`TRANSFER_ESCROW:  ${await teProxy.getAddress()}`);
}

main().catch(e => { console.error(e); process.exit(1); });
