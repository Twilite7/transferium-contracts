import { network } from "hardhat";
async function main() {
  const { ethers } = await network.connect();
  const [deployer, club, hijacker] = await ethers.getSigners();
  const EURC = "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a";
  const eurc = new ethers.Contract(EURC, [
    "function balanceOf(address) view returns (uint256)",
    "function transfer(address,uint256) external returns (bool)",
  ], deployer);

  console.log("deployer EURC:", ethers.formatUnits(await eurc.balanceOf(deployer.address), 6));
  console.log("hijacker EURC:", ethers.formatUnits(await eurc.balanceOf(hijacker.address), 6));

  // Top hijacker up to 20 EURC
  const hijBal = await eurc.balanceOf(hijacker.address);
  const needed = ethers.parseUnits("20", 6) - hijBal;
  if (needed > 0n) {
    await (await eurc.transfer(hijacker.address, needed)).wait();
    console.log("Topped hijacker up by", ethers.formatUnits(needed, 6), "EURC");
  }
  console.log("hijacker EURC now:", ethers.formatUnits(await eurc.balanceOf(hijacker.address), 6));
}
main().catch(console.error);
