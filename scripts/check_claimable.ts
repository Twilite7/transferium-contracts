import { network } from "hardhat";
async function main() {
  const { ethers } = await network.connect();
  const [deployer, club, hijacker] = await ethers.getSigners();
  const DEAL = "0x715651035d9a5e5d455263AA468Adce0eaA9519a";
  const EURC = "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a";
  const eurc = new ethers.Contract(EURC, ["function balanceOf(address) view returns (uint256)"], deployer);
  const deal = new ethers.Contract(DEAL, [
    "function getClaimable(address,address) view returns (uint256)",
    "function withdrawClaimable(address) external",
  ], deployer);

  const depClaimable = await deal.getClaimable(deployer.address, EURC);
  const hijClaimable = await deal.getClaimable(hijacker.address, EURC);
  console.log("deployer claimable:", ethers.formatUnits(depClaimable, 6), "EURC");
  console.log("hijacker claimable:", ethers.formatUnits(hijClaimable, 6), "EURC");

  if (depClaimable > 0n) {
    await (await deal.withdrawClaimable(EURC)).wait();
    console.log("Deployer withdrew", ethers.formatUnits(depClaimable, 6), "EURC");
  }
  if (hijClaimable > 0n) {
    const dealHij = new ethers.Contract(DEAL, ["function withdrawClaimable(address) external"], hijacker);
    await (await dealHij.withdrawClaimable(EURC)).wait();
    console.log("Hijacker withdrew", ethers.formatUnits(hijClaimable, 6), "EURC");
  }

  console.log("\nFinal balances:");
  console.log("deployer:", ethers.formatUnits(await eurc.balanceOf(deployer.address), 6));
  console.log("hijacker:", ethers.formatUnits(await eurc.balanceOf(hijacker.address), 6));
}
main().catch(console.error);
