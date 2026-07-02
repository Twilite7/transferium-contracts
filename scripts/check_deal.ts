import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  const dealEscrow = await ethers.getContractAt(
    "DealEscrow",
    "0x16FA8AD457C9aA5A65E1b6bfffb21E87740c909C"
  );

  const d = await dealEscrow.getDealView(1);
  console.log("state (raw number):", d.state.toString());
  console.log("deadline:", new Date(Number(d.stateDeadline) * 1000).toISOString());
  const now = Math.floor(Date.now() / 1000);
  console.log("remaining:", Number(d.stateDeadline) - now, "seconds");
}

main().catch(console.error);
