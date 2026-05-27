import { network } from "hardhat";
async function main() {
  const { ethers } = await network.connect();
  const [deployer, club, hijacker] = await ethers.getSigners();
  const DEAL = "0x715651035d9a5e5d455263AA468Adce0eaA9519a";
  const EURC = "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a";

  const deal = new ethers.Contract(DEAL, [
    "function totalDeals() view returns (uint256)",
    "function getDealView(uint256) view returns (tuple(bool exists, address sellingClub, address buyingClub, address paymentToken, uint256 transferFee, uint256 minimumHijackIncrementBps, uint8 state, uint256 stateDeadline))",
    "function getClaimable(address,address) view returns (uint256)",
    "function getExpiryView(uint256) view returns (bool exists, bool frozen, uint8 state, uint256 stateDeadline, address paymentToken, uint256 transferFee)",
  ], deployer);
  const eurc = new ethers.Contract(EURC, ["function balanceOf(address) view returns (uint256)"], deployer);

  // Check claimable for ALL possible addresses including treasury, agents, sell-on recipients
  const addrsToCheck = [
    [deployer.address, "deployer"],
    [club.address,     "club"],
    [hijacker.address, "hijacker"],
    ["0x0000000000000000000000000000000000000000", "zero"],
  ];

  console.log("=== CLAIMABLE ALL ===");
  for (const [addr, label] of addrsToCheck) {
    const c = await deal.getClaimable(addr, EURC);
    if (c > 0n) console.log(label, ":", ethers.formatUnits(c, 6));
  }

  console.log("\n=== DEALS IN FUNDING_PENDING (state 13) ===");
  const total = await deal.totalDeals();
  let fundingTotal = 0n;
  for (let i = 1n; i <= total; i++) {
    const d = await deal.getDealView(i);
    if (!d.exists) continue;
    if (Number(d.state) === 13) {
      const ev = await deal.getExpiryView(i);
      console.log(`Deal #${i}: fee=€${ethers.formatUnits(d.transferFee,6)} deadline=${ev.stateDeadline} buyer=${d.buyingClub.slice(0,10)}`);
      // These deals are FUNDING_PENDING — was any payment already deposited?
      // In our flow, payment happens at fundDeal, so state 13 means NO funds deposited yet
    }
  }

  console.log("\nDealEscrow balance:", ethers.formatUnits(await eurc.balanceOf(DEAL), 6));
  console.log("\nNote: deals in FUNDING_PENDING have NO funds locked —");
  console.log("funds are only pulled at fundDeal(). The 12.2 EURC must be");
  console.log("from completed deal #8 fee distribution (protocol + sell-on + agents)");
  console.log("that went to deployer as treasury/agent but wasn't withdrawn yet.");

  // Double-check deployer claimable one more time
  const depClaim = await deal.getClaimable(deployer.address, EURC);
  console.log("\nDeployer claimable (recheck):", ethers.formatUnits(depClaim, 6));
}
main().catch(console.error);
