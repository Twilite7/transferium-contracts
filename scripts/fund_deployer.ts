import { network } from "hardhat";
async function main() {
  const { ethers } = await network.connect();
  const [deployer, club] = await ethers.getSigners();
  const EURC = "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a";
  const eurc = new ethers.Contract(EURC, [
    "function transfer(address,uint256) external returns (bool)",
    "function balanceOf(address) view returns (uint256)",
  ], club);
  await (await eurc.transfer(deployer.address, ethers.parseUnits("80", 6))).wait();
  console.log("deployer EURC:", ethers.formatUnits(await eurc.balanceOf(deployer.address), 6));
  console.log("club     EURC:", ethers.formatUnits(await eurc.balanceOf(club.address), 6));
}
main().catch(console.error);
