import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const REGISTRY = "0x1aFCB3929E653ACdaCfDeAf2CfcfF083B194F962";

  const abi = [
    "function hasRole(bytes32,address) view returns (bool)",
    "function grantRole(bytes32,address)",
    "function CLUB_ROLE() view returns (bytes32)",
    "function REGISTRAR_ROLE() view returns (bytes32)",
  ];

  const registry = new ethers.Contract(REGISTRY, abi, deployer);

  const CLUB_ROLE      = await registry.CLUB_ROLE();
  const REGISTRAR_ROLE = await registry.REGISTRAR_ROLE();

  const hasClub      = await registry.hasRole(CLUB_ROLE,      deployer.address);
  const hasRegistrar = await registry.hasRole(REGISTRAR_ROLE, deployer.address);

  console.log("Has CLUB_ROLE:     ", hasClub);
  console.log("Has REGISTRAR_ROLE:", hasRegistrar);

  if (!hasClub) {
    console.log("Granting CLUB_ROLE...");
    const tx = await registry.grantRole(CLUB_ROLE, deployer.address, { gasLimit: 100000 });
    await tx.wait();
    console.log("CLUB_ROLE granted.");
  }

  if (!hasRegistrar) {
    console.log("Granting REGISTRAR_ROLE...");
    const tx = await registry.grantRole(REGISTRAR_ROLE, deployer.address, { gasLimit: 100000 });
    await tx.wait();
    console.log("REGISTRAR_ROLE granted.");
  }

  console.log("Done — deployer has all roles needed for testing.");
}

main().catch(e => { console.error(e); process.exit(1); });
