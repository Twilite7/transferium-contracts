import { network } from "hardhat";
async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();
  const DEAL = "0x715651035d9a5e5d455263AA468Adce0eaA9519a";
  const EURC = "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a";

  const deal = new ethers.Contract(DEAL, [
    "function getDealView(uint256) view returns (tuple(bool exists, address sellingClub, address buyingClub, address paymentToken, uint256 transferFee, uint256 minimumHijackIncrementBps, uint8 state, uint256 stateDeadline))",
    "function getExpiryView(uint256) view returns (bool exists, bool frozen, uint8 state, uint256 stateDeadline, address paymentToken, uint256 transferFee)",
    "function getClaimable(address,address) view returns (uint256)",
  ], deployer);

  const d  = await deal.getDealView(1n);
  const ev = await deal.getExpiryView(1n);
  const block = await ethers.provider.getBlock("latest");
  const now   = BigInt(block!.timestamp);

  console.log("Deal #1:");
  console.log("  state:       ", d.state.toString(), "(13=FUNDING_PENDING)");
  console.log("  transferFee: €" + ethers.formatUnits(d.transferFee, 6));
  console.log("  buyingClub:  ", d.buyingClub);
  console.log("  sellingClub: ", d.sellingClub);
  console.log("  deadline:    ", ev.stateDeadline.toString());
  console.log("  now:         ", now.toString());
  console.log("  expires in:  ", Number(ev.stateDeadline - now) / 3600, "hours");
  console.log("  locked EURC in DealEscrow:", ethers.formatUnits(await new ethers.Contract(EURC, ["function balanceOf(address) view returns (uint256)"], deployer).balanceOf(DEAL), 6));
}
main().catch(console.error);
