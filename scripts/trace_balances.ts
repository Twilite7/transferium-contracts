import { network } from "hardhat";
async function main() {
  const { ethers } = await network.connect();
  const [deployer, club, hijacker] = await ethers.getSigners();
  const DEAL     = "0x715651035d9a5e5d455263AA468Adce0eaA9519a";
  const ESCROW   = "0xEf74E315296B65ffCF04e66B96cc1Ffa35CBeDCD";
  const REGISTRY = "0xAe7e07e3623448A918198DDF68D0C788A9c86636";
  const EURC     = "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a";

  const eurc = new ethers.Contract(EURC, [
    "function balanceOf(address) view returns (uint256)",
  ], deployer);
  const deal = new ethers.Contract(DEAL, [
    "function totalDeals() view returns (uint256)",
    "function getDealView(uint256) view returns (tuple(bool exists, address sellingClub, address buyingClub, address paymentToken, uint256 transferFee, uint256 minimumHijackIncrementBps, uint8 state, uint256 stateDeadline))",
    "function getClaimable(address,address) view returns (uint256)",
  ], deployer);

  console.log("=== BALANCES ===");
  console.log("deployer:", ethers.formatUnits(await eurc.balanceOf(deployer.address), 6));
  console.log("club:    ", ethers.formatUnits(await eurc.balanceOf(club.address), 6));
  console.log("hijacker:", ethers.formatUnits(await eurc.balanceOf(hijacker.address), 6));
  console.log("DealEscrow:", ethers.formatUnits(await eurc.balanceOf(DEAL), 6));
  console.log("TransferEscrow:", ethers.formatUnits(await eurc.balanceOf(ESCROW), 6));
  console.log("PlayerRegistry:", ethers.formatUnits(await eurc.balanceOf(REGISTRY), 6));

  console.log("\n=== CLAIMABLE ===");
  console.log("deployer:", ethers.formatUnits(await deal.getClaimable(deployer.address, EURC), 6));
  console.log("club:    ", ethers.formatUnits(await deal.getClaimable(club.address, EURC), 6));
  console.log("hijacker:", ethers.formatUnits(await deal.getClaimable(hijacker.address, EURC), 6));

  console.log("\n=== ALL DEALS ===");
  const total = await deal.totalDeals();
  const stateNames: Record<number, string> = {
    0:"NONE",1:"CREATED",2:"CONSENT_PENDING",3:"AWAITING_CONSENT",4:"RENEGOTIATION",
    5:"AWAITING_PLAYER_CONSENT",6:"AWAITING_TRANSFER_MEDICAL",7:"MEDICAL_RENEGOTIATION",
    8:"MEDICAL_DISPUTE",9:"HIJACK_WINDOW",10:"AWAITING_HIJACK_CONSENT",
    11:"AWAITING_HIJACK_MEDICAL",12:"MUTUAL_CANCEL",13:"FUNDING_PENDING",
    14:"FUNDED",15:"DISPUTE_WINDOW",16:"COMPLETED",17:"CANCELLED"
  };
  for (let i = 1n; i <= total; i++) {
    const d = await deal.getDealView(i);
    if (!d.exists) continue;
    console.log(`Deal #${i}: state=${d.state}(${stateNames[Number(d.state)]??'?'}) fee=€${ethers.formatUnits(d.transferFee,6)} buyer=${d.buyingClub.slice(0,8)} seller=${d.sellingClub.slice(0,8)}`);
  }
}
main().catch(console.error);
