import { network } from "hardhat";
async function main() {
  const { ethers } = await network.connect();
  const [deployer, club, hijacker] = await ethers.getSigners();
  const EURC = "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a";
  const eurc = new ethers.Contract(EURC, ["function balanceOf(address) view returns (uint256)"], deployer);
  console.log("deployer:", ethers.formatUnits(await eurc.balanceOf(deployer.address), 6));
  console.log("club:    ", ethers.formatUnits(await eurc.balanceOf(club.address), 6));
  console.log("hijacker:", ethers.formatUnits(await eurc.balanceOf(hijacker.address), 6));
}
main().catch(console.error);
