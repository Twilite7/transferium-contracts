import { network } from "hardhat";
async function main() {
  const { ethers } = await network.connect();
  const [deployer, club, hijacker] = await ethers.getSigners();
  const DEAL = "0x9Faade3f7916D40dB55121CeFD789F048CAC7c06";
  const EURC = "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a";

  const deal = new ethers.Contract(DEAL, [
    "function totalDeals() view returns (uint256)",
    "function getDealView(uint256) view returns (tuple(bool exists, address sellingClub, address buyingClub, address paymentToken, uint256 transferFee, uint256 minimumHijackIncrementBps, uint8 state, uint256 stateDeadline))",
    "function getClaimable(address,address) view returns (uint256)",
    "function withdrawClaimable(address) external",
    "function processExpiry(uint256) external",
  ], deployer);
  const eurc = new ethers.Contract(EURC, ["function balanceOf(address) view returns (uint256)"], deployer);

  const total = await deal.totalDeals();
  const escrowBal = await eurc.balanceOf(DEAL);
  console.log("DealEscrow balance:", ethers.formatUnits(escrowBal, 6), "EURC");
  console.log("Total deals:", total.toString());

  const states: Record<number, number> = {};
  const funded: bigint[] = [];
  for (let i = 1n; i <= total; i++) {
    const d = await deal.getDealView(i);
    if (!d.exists) continue;
    const s = Number(d.state);
    states[s] = (states[s] || 0) + 1;
    if (s === 14) funded.push(i); // FUNDED — can processExpiry if deadline passed
  }
  console.log("\nState breakdown:", states);
  console.log("FUNDED deals (may have locked funds):", funded.map(n => n.toString()));

  // Try processExpiry on funded deals past their deadline
  for (const did of funded) {
    const d = await deal.getDealView(did);
    const now = BigInt(Math.floor(Date.now() / 1000));
    if (now > d.stateDeadline) {
      try {
        await (await deal.processExpiry(did)).wait();
        console.log("  processExpiry deal #" + did.toString() + " → COMPLETED");
      } catch (e: any) { console.log("  processExpiry #" + did + " failed:", e.data ?? e.message?.slice(0,40)); }
    } else {
      console.log("  Deal #" + did + " dispute window still open (expires", new Date(Number(d.stateDeadline)*1000).toISOString() + ")");
    }
  }

  // Withdraw all claimable for all signers
  for (const [signer, label] of [[deployer,"deployer"],[club,"club"],[hijacker,"hijacker"]] as const) {
    const c = await deal.getClaimable(signer.address, EURC);
    if (c > 0n) {
      const d2 = new ethers.Contract(DEAL, ["function withdrawClaimable(address) external"], signer);
      await (await d2.withdrawClaimable(EURC)).wait();
      console.log("Withdrew", ethers.formatUnits(c, 6), "EURC for", label);
    }
  }

  console.log("\nDealEscrow balance after recovery:", ethers.formatUnits(await eurc.balanceOf(DEAL), 6));
}
main().catch(console.error);
