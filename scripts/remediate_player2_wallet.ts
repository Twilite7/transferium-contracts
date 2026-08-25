import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  ethers.provider.pollingInterval = 15000;

  const REGISTRY = "0x21962C5548aeD0Ca83c8a1Bf051FE221CB9De4f9";
  const DEPLOYER = "0x13E569C96c7F884443d0c3Ac5019D020dE32bFb3";
  const registry = await ethers.getContractAt("PlayerRegistry", REGISTRY);
  const [deployer] = await ethers.getSigners();

  const VERIFICATION_ROLE = await registry.VERIFICATION_ROLE();

  console.log("1. Granting VERIFICATION_ROLE to deployer temporarily...");
  let tx = await registry.connect(deployer).grantRole(VERIFICATION_ROLE, DEPLOYER);
  await tx.wait();
  console.log("   ✓ Granted:", tx.hash);

  console.log("\n2. Resetting player 2's wallet...");
  tx = await registry.connect(deployer).resetWallet(2, DEPLOYER);
  await tx.wait();
  console.log("   ✓ Reset:", tx.hash);

  console.log("\n3. Revoking the temporary VERIFICATION_ROLE...");
  tx = await registry.connect(deployer).revokeRole(VERIFICATION_ROLE, DEPLOYER);
  await tx.wait();
  console.log("   ✓ Revoked:", tx.hash);

  console.log("\nVerifying final state...");
  const player = await registry.getPlayer(2);
  console.log("Player 2 wallet now:", player.playerWallet);
  const stillHasRole = await registry.hasRole(VERIFICATION_ROLE, DEPLOYER);
  console.log("Deployer still holds VERIFICATION_ROLE:", stillHasRole, "(should be false)");
}

main().catch(console.error);
