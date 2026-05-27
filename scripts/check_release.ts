import { network } from "hardhat";
async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();
  const RELEASE = "0xf1ce6CC66A5cE8Cae8d0f73Ee57027AdfD2F0c2F";
  const rel = new ethers.Contract(RELEASE, [
    "function CLUB_ROLE() view returns (bytes32)",
    "function LEAGUE_ROLE() view returns (bytes32)",
    "function hasRole(bytes32,address) view returns (bool)",
    "function isTokenApproved(address) view returns (bool)",
    "function paused() view returns (bool)",
    "function transferEscrow() view returns (address)",
    "function transferWindow() view returns (address)",
    "function playerRegistry() view returns (address)",
    "function setConsentWindow(uint256) external",
  ], deployer);
  const EURC = "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a";
  const cr = await rel.CLUB_ROLE();
  const lr = await rel.LEAGUE_ROLE();
  console.log("CLUB_ROLE ok");
  console.log("paused:", await rel.paused());
  console.log("EURC approved:", await rel.isTokenApproved(EURC));
  console.log("deployer hasClub:", await rel.hasRole(cr, deployer.address));
  console.log("deployer hasLeague:", await rel.hasRole(lr, deployer.address));
  console.log("transferEscrow:", await rel.transferEscrow());
  console.log("transferWindow:", await rel.transferWindow());
  console.log("playerRegistry:", await rel.playerRegistry());
  // staticCall setConsentWindow to see what reverts
  try {
    await rel.setConsentWindow.staticCall(15);
    console.log("setConsentWindow(15) staticCall PASSED");
  } catch (e: any) {
    console.log("setConsentWindow(15) FAILED:", e.data ?? e.message?.slice(0,80));
  }
}
main().catch(console.error);
