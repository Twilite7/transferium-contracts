import { network } from "hardhat";
async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();
  const DEAL   = "0x9Faade3f7916D40dB55121CeFD789F048CAC7c06";
  const ESCROW = "0x04B223438101cE75e07806A9b3accDc978a9df5B";
  const EURC   = "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a";

  const escrow = new ethers.Contract(ESCROW, ["function processExpiry(uint256) external"], deployer);
  const deal   = new ethers.Contract(DEAL,   ["function getClaimable(address,address) view returns (uint256)", "function withdrawClaimable(address) external"], deployer);
  const eurc   = new ethers.Contract(EURC,   ["function balanceOf(address) view returns (uint256)"], deployer);

  for (const id of [8n, 13n, 18n]) {
    try {
      // processExpiry lives on TransferEscrow, not DealEscrow
      await (await escrow.processExpiry(id)).wait();
      console.log("processExpiry #" + id + " OK");
    } catch (e: any) {
      console.log("processExpiry #" + id + " failed:", e.data ?? e.message?.slice(0,60));
    }
  }

  for (const [signer, label] of [[deployer, "deployer"]] as const) {
    const c = await deal.getClaimable(signer.address, EURC);
    console.log(label, "claimable:", ethers.formatUnits(c, 6));
    if (c > 0n) await (await new ethers.Contract(DEAL, ["function withdrawClaimable(address) external"], signer).withdrawClaimable(EURC)).wait();
  }

  console.log("DealEscrow balance:", ethers.formatUnits(await eurc.balanceOf(DEAL), 6));
}
main().catch(console.error);
