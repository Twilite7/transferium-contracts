import { network } from "hardhat";
async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();
  const DEAL = "0x9Faade3f7916D40dB55121CeFD789F048CAC7c06";
  const deal = new ethers.Contract(DEAL, [
    "function totalDeals() view returns (uint256)",
    "function getDealView(uint256) view returns (tuple(bool exists, address sellingClub, address buyingClub, address paymentToken, uint256 transferFee, uint256 minimumHijackIncrementBps, uint8 state, uint256 stateDeadline))",
    "function getDealAddOns(uint256) view returns (tuple(string description, uint256 amount, bool toPlayer, bool triggered)[])",
  ], deployer);
  const total = await deal.totalDeals();
  console.log("Total deals:", total.toString());
  for (let i = 1n; i <= total; i++) {
    const d = await deal.getDealView(i);
    if (!d.exists) continue;
    let addons: any[] = [];
    try { addons = await deal.getDealAddOns(i); } catch {}
    console.log(`Deal #${i}: state=${d.state} addons=${addons.length}`);
  }
}
main().catch(console.error);
