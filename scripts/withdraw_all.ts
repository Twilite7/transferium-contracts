import { network } from "hardhat";
async function main() {
  const { ethers } = await network.connect();
  const [deployer, club, hijacker] = await ethers.getSigners();
  const DEAL = "0x9Faade3f7916D40dB55121CeFD789F048CAC7c06";
  const EURC = "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a";
  const eurc = new ethers.Contract(EURC, ["function balanceOf(address) view returns (uint256)"], deployer);

  for (const [signer, label] of [[deployer,"deployer"],[club,"club"],[hijacker,"hijacker"]] as const) {
    const d = new ethers.Contract(DEAL, ["function getClaimable(address,address) view returns (uint256)", "function withdrawClaimable(address) external"], signer);
    const c = await d.getClaimable(signer.address, EURC);
    console.log(label, "claimable:", ethers.formatUnits(c, 6));
    if (c > 0n) { await (await d.withdrawClaimable(EURC)).wait(); console.log("  withdrawn"); }
  }

  console.log("\nDealEscrow balance:", ethers.formatUnits(await eurc.balanceOf(DEAL), 6));
  console.log("Remainder = signing bonuses locked to throwaway player wallets");
  console.log("Recoverable via rescueSigningBonus() after 90 days per deal");
}
main().catch(console.error);
