import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const PLAYER_REGISTRY = "0xFA8dCb6f0DB181DD9400888a1e0874Ebba94D7bA";
  const OLD_VMGR        = "0x979F9E297FAE9e4F2dDf4f091Fadbc1E1491f918";

  const registryABI = [
    "function grantVerificationRole(address verifier) external",
    "function hasRole(bytes32, address) view returns (bool)",
    "function revokeRole(bytes32, address) external",
  ];
  const registry = new ethers.Contract(PLAYER_REGISTRY, registryABI, deployer);

  // I compute VERIFICATION_ROLE locally — same as keccak256("VERIFICATION_ROLE") in the contract
  const VERIFICATION_ROLE = ethers.id("VERIFICATION_ROLE");

  // I deploy the updated VerificationManager
  const Factory = await ethers.getContractFactory("VerificationManager", deployer);
  const vm = await Factory.deploy(PLAYER_REGISTRY, deployer.address);
  await vm.waitForDeployment();
  const vmAddr = await vm.getAddress();
  console.log("New VerificationManager:", vmAddr);

  // I revoke VERIFICATION_ROLE from the old VerificationManager
  const oldHasRole = await registry.hasRole(VERIFICATION_ROLE, OLD_VMGR);
  if (oldHasRole) {
    await (await registry.revokeRole(VERIFICATION_ROLE, OLD_VMGR)).wait();
    console.log("VERIFICATION_ROLE revoked from old VerificationManager");
  } else {
    console.log("Old VerificationManager did not have VERIFICATION_ROLE — skipping revoke");
  }

  // I grant VERIFICATION_ROLE to the new VerificationManager
  await (await registry.grantVerificationRole(vmAddr)).wait();
  console.log("VERIFICATION_ROLE granted to new VerificationManager");

  console.log("\n=== Update frontend contracts.ts with: ===");
  console.log(`  VerificationManager: '${vmAddr}',`);
}

main().catch(e => { console.error(e); process.exit(1); });
