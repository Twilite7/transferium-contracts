import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  const registry = await ethers.getContractAt(
    "PlayerRegistry",
    "0x2bc403A55Bc895AbaD40F912eE43a01D6Aad8767"
  );

  const deployer = "0x13E569C96c7F884443d0c3Ac5019D020dE32bFb3";

  const [ADMIN_ROLE, CLUB_ROLE, REGISTRAR_ROLE, DEFAULT_ADMIN] = await Promise.all([
    registry.ADMIN_ROLE(),
    registry.CLUB_ROLE(),
    registry.REGISTRAR_ROLE(),
    Promise.resolve("0x0000000000000000000000000000000000000000000000000000000000000000"),
  ]);

  const [isAdmin, isClub, isRegistrar, isDefaultAdmin] = await Promise.all([
    registry.hasRole(ADMIN_ROLE,    deployer),
    registry.hasRole(CLUB_ROLE,     deployer),
    registry.hasRole(REGISTRAR_ROLE, deployer),
    registry.hasRole(DEFAULT_ADMIN,  deployer),
  ]);

  console.log("ADMIN_ROLE:        ", isAdmin);
  console.log("CLUB_ROLE:         ", isClub);
  console.log("REGISTRAR_ROLE:    ", isRegistrar);
  console.log("DEFAULT_ADMIN_ROLE:", isDefaultAdmin);
}

main().catch(console.error);
