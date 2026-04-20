import { network } from "hardhat";
import addresses from "../deployments/addresses.json";

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();

  const abi = [
    "function hasRole(bytes32 role, address account) external view returns (bool)",
    "function CLUB_ROLE() external view returns (bytes32)",
    "function REGISTRAR_ROLE() external view returns (bytes32)",
    "function ESCROW_ROLE() external view returns (bytes32)",
  ];

  const registry = await ethers.getContractAt(abi, addresses.PlayerRegistry, deployer);

  const CLUB_ROLE      = await registry.CLUB_ROLE();
  const REGISTRAR_ROLE = await registry.REGISTRAR_ROLE();
  const ESCROW_ROLE    = await registry.ESCROW_ROLE();

  console.log(`Deployer: ${deployer.address}`);
  console.log(`CLUB_ROLE      : ${await registry.hasRole(CLUB_ROLE, deployer.address)}`);
  console.log(`REGISTRAR_ROLE : ${await registry.hasRole(REGISTRAR_ROLE, deployer.address)}`);
  console.log(`ESCROW_ROLE    : ${await registry.hasRole(ESCROW_ROLE, deployer.address)}`);
}

main().catch(err => { console.error(err); process.exit(1); });
