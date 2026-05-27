import { network } from "hardhat";
import addresses from '../deployments/addresses.json';

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();

  const CLUB_WALLET = "0xF6EE621FcFceE360Bf3BbA8707144a58B0028F85";

  const ABI = [
    "function CLUB_ROLE() view returns (bytes32)",
    "function grantRole(bytes32,address) external",
    "function setClubName(address,string) external",
  ];

  const registry   = new ethers.Contract(addresses.PlayerRegistry, ABI, deployer);
  const transfer   = new ethers.Contract(addresses.TransferEscrow,  ABI, deployer);
  const loanEscrow = new ethers.Contract(addresses.LoanEscrow,      ABI, deployer);

  const CLUB_ROLE = await registry.CLUB_ROLE();

  for (const [name, contract] of [["PlayerRegistry", registry], ["TransferEscrow", transfer], ["LoanEscrow", loanEscrow]] as const) {
    await (await contract.grantRole(CLUB_ROLE, CLUB_WALLET)).wait();
    console.log(`CLUB_ROLE granted on ${name}`);
  }

  await (await registry.setClubName(CLUB_WALLET, "FC Barcelona")).wait();
  console.log("Club name set: FC Barcelona");
}

main().catch(console.error);
