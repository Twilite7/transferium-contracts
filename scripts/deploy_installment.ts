import { network } from "hardhat";
import fs from "fs";

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();

  const DEAL_ESCROW = "0x9Faade3f7916D40dB55121CeFD789F048CAC7c06";
  const TREASURY    = deployer.address;
  const FEE_BPS     = 50;

  const Factory = await ethers.getContractFactory("InstallmentEscrow");
  const contract = await Factory.deploy(DEAL_ESCROW, TREASURY, FEE_BPS);
  await contract.waitForDeployment();
  const addr = await contract.getAddress();
  console.log("InstallmentEscrow:", addr);

  // Grant TRANSFER_ESCROW_ROLE on DealEscrow to InstallmentEscrow
  const dealEscrow = new ethers.Contract(DEAL_ESCROW, [
    "function grantRole(bytes32,address) external",
    "function TRANSFER_ESCROW_ROLE() view returns (bytes32)",
  ], deployer);
  const role = await dealEscrow.TRANSFER_ESCROW_ROLE();
  await (await dealEscrow.grantRole(role, addr)).wait();
  console.log("Granted TRANSFER_ESCROW_ROLE");

  // Save to addresses.json
  const addrFile = '/home/kali/transferium-contracts/deployments/addresses.json';
  const existing = JSON.parse(fs.readFileSync(addrFile, 'utf8'));
  existing.InstallmentEscrow = addr;
  fs.writeFileSync(addrFile, JSON.stringify(existing, null, 2));
  console.log("Saved to addresses.json");

  return addr;
}

main().catch(console.error);
