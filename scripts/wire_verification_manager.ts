import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();

  const PLAYER_REGISTRY   = "0xFA8dCb6f0DB181DD9400888a1e0874Ebba94D7bA";
  const NEW_VMGR          = "0x0ad1c42A82502157C05C68c2673dCaab00Df5EeC";
  const VERIFICATION_ROLE = ethers.id("VERIFICATION_ROLE");

  const registry = new ethers.Contract(PLAYER_REGISTRY, [
    "function grantRole(bytes32 role, address account) external",
    "function hasRole(bytes32, address) view returns (bool)",
  ], deployer);

  const alreadyHas = await registry.hasRole(VERIFICATION_ROLE, NEW_VMGR);
  if (alreadyHas) {
    console.log("New VerificationManager already has VERIFICATION_ROLE — nothing to do");
    return;
  }

  // I use the standard OpenZeppelin grantRole directly since DEFAULT_ADMIN_ROLE
  // can bypass the custom grantVerificationRole wrapper
  await (await registry.grantRole(VERIFICATION_ROLE, NEW_VMGR)).wait();
  console.log("VERIFICATION_ROLE granted to:", NEW_VMGR);

  const confirmed = await registry.hasRole(VERIFICATION_ROLE, NEW_VMGR);
  console.log("Confirmed:", confirmed);
}

main().catch(e => { console.error(e); process.exit(1); });
