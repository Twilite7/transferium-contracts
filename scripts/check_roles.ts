import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();

  const PLAYER_REGISTRY = "0xFA8dCb6f0DB181DD9400888a1e0874Ebba94D7bA";
  const NEW_VMGR        = "0x0ad1c42A82502157C05C68c2673dCaab00Df5EeC";

  const registry = new ethers.Contract(PLAYER_REGISTRY, [
    "function hasRole(bytes32, address) view returns (bool)",
  ], ethers.provider);

  const roles = {
    DEFAULT_ADMIN: "0x0000000000000000000000000000000000000000000000000000000000000000",
    ADMIN_ROLE:    ethers.id("ADMIN_ROLE"),
    VERIFICATION:  ethers.id("VERIFICATION_ROLE"),
  };

  for (const [name, role] of Object.entries(roles)) {
    const has = await registry.hasRole(role, deployer.address);
    console.log(`${name}: deployer=${has}`);
    if (name === "VERIFICATION") {
      const vmgrHas = await registry.hasRole(role, NEW_VMGR);
      console.log(`${name}: new_vmgr=${vmgrHas}`);
    }
  }
}

main().catch(e => { console.error(e); process.exit(1); });
