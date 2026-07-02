import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  const PROXY = "0xFA8dCb6f0DB181DD9400888a1e0874Ebba94D7bA";

  // Try both upgrade function signatures
  const abi = [
    "function upgradeToAndCall(address newImplementation, bytes calldata data) external",
    "function upgradeTo(address newImplementation) external",
    "function implementation() view returns (address)",
    "function proxiableUUID() view returns (bytes32)",
    "function hasRole(bytes32, address) view returns (bool)",
  ];

  const proxy = new ethers.Contract(PROXY, abi, ethers.provider);
  const [deployer] = await ethers.getSigners();

  try {
    const uuid = await proxy.proxiableUUID();
    console.log("proxiableUUID:", uuid);
  } catch { console.log("proxiableUUID: not found"); }

  try {
    const impl = await proxy.implementation();
    console.log("current implementation:", impl);
  } catch { console.log("implementation(): not exposed"); }

  // Check deployer has DEFAULT_ADMIN_ROLE
  const DEFAULT_ADMIN = "0x0000000000000000000000000000000000000000000000000000000000000000";
  const ADMIN_ROLE    = ethers.id("ADMIN_ROLE");
  console.log("deployer DEFAULT_ADMIN:", await proxy.hasRole(DEFAULT_ADMIN, deployer.address));
  console.log("deployer ADMIN_ROLE:", await proxy.hasRole(ADMIN_ROLE, deployer.address));

  // Try static-call upgradeTo to get a better revert reason
  const proxy2 = new ethers.Contract(PROXY, [
    "function upgradeTo(address) external",
  ], deployer);
  try {
    await proxy2.upgradeTo.staticCall("0x4f465F051602d68bfa756d14E7Ab9d2C7b085091");
    console.log("upgradeTo staticCall: would succeed");
  } catch (e: any) {
    console.log("upgradeTo revert reason:", e.message?.slice(0, 200));
  }
}

main().catch(e => { console.error(e); process.exit(1); });
