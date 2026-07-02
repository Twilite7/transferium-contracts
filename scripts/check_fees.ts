import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  const registry = await ethers.getContractAt(
    "PlayerRegistry",
    "0x218b8d89627Ee2bBf56e3Da1717F908f0E07A27e"
  );

  const registrar = "0x0ad1c42A82502157C05C68c2673dCaab00Df5EeC";

  const [baseFee, registrarFee, protocolBps, claimable] = await Promise.all([
    registry.baseVerificationFee(),
    registry.getRegistrarFee(registrar),
    registry.protocolFeeBps(),
    registry.getRegistrarClaimable(registrar),
  ]);

  console.log("Base verification fee:", ethers.formatUnits(baseFee, 6), "EURC");
  console.log("Registrar fee:        ", ethers.formatUnits(registrarFee, 6), "EURC");
  console.log("Protocol fee:         ", protocolBps.toString(), "bps (", Number(protocolBps)/100, "%)");
  console.log("Registrar claimable:  ", ethers.formatUnits(claimable, 6), "EURC");
  console.log("\nRegistrar must call setVerificationFee() to set their fee.");
  console.log("Max allowed: ", ethers.formatUnits(baseFee * 12000n / 10000n, 6), "EURC (120% of base)");
}

main().catch(console.error);
