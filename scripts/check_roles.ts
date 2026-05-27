import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();

  const registry = new ethers.Contract(
    "0x4EB83Ae9092b154fB87C5c17632b3aa181AD3201",
    [
      "function CLUB_ROLE() view returns (bytes32)",
      "function REGISTRAR_ROLE() view returns (bytes32)",
      "function hasRole(bytes32,address) view returns (bool)",
    ],
    deployer
  );

  const CLUB_ROLE      = await registry.CLUB_ROLE();
  const REGISTRAR_ROLE = await registry.REGISTRAR_ROLE();

  const deployer_addr = deployer.address;
  const club_wallet   = "0xF6EE621FcFceE360Bf3BbA8707144a58B0028F85";

  console.log("--- Deployer ---");
  console.log("CLUB_ROLE:      ", await registry.hasRole(CLUB_ROLE,      deployer_addr));
  console.log("REGISTRAR_ROLE: ", await registry.hasRole(REGISTRAR_ROLE, deployer_addr));

  console.log("--- Club wallet ---");
  console.log("CLUB_ROLE:      ", await registry.hasRole(CLUB_ROLE,      club_wallet));
  console.log("REGISTRAR_ROLE: ", await registry.hasRole(REGISTRAR_ROLE, club_wallet));
}

main().catch(console.error);
