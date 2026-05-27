import { network } from "hardhat";
async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();
  const DEAL = "0x9Faade3f7916D40dB55121CeFD789F048CAC7c06";
  const deal = new ethers.Contract(DEAL, [
    "function getDealView(uint256) view returns (tuple(bool exists, address sellingClub, address buyingClub, address paymentToken, uint256 transferFee, uint256 minimumHijackIncrementBps, uint8 state, uint256 stateDeadline))",
    "function getInstallment(uint256,uint8) view returns (tuple(uint256 amount, uint256 dueDate, bool paid))",
  ], deployer);

  const now = BigInt(Math.floor(Date.now() / 1000));
  for (const id of [8n, 13n, 18n]) {
    const d = await deal.getDealView(id);
    const inst = await deal.getInstallment(id, 0);
    const secsLeft = Number(d.stateDeadline) - Number(now);
    console.log(`Deal #${id}: transferFee=€${ethers.formatUnits(inst.amount,6)} deadline=${new Date(Number(d.stateDeadline)*1000).toISOString()} (${secsLeft > 0 ? secsLeft+"s remaining" : "EXPIRED"})`);
  }
}
main().catch(console.error);
