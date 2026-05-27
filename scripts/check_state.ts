import { network } from "hardhat";
async function main() {
  const { ethers } = await network.connect();
  const [deployer, club] = await ethers.getSigners();

  const EURC = new ethers.Contract("0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a", [
    "function balanceOf(address) view returns (uint256)",
    "function decimals() view returns (uint8)",
  ], deployer);

  const registry = new ethers.Contract("0x1aFCB3929E653ACdaCfDeAf2CfcfF083B194F962", [
    "function hasRole(bytes32, address) view returns (bool)",
    "function CLUB_ROLE() view returns (bytes32)",
    "function REGISTRAR_ROLE() view returns (bytes32)",
  ], deployer);

  const escrow = new ethers.Contract("0x445B52f961Fde3A6eD60c43aC3127Fc460674B99", [
    "function hasRole(bytes32, address) view returns (bool)",
    "function CLUB_ROLE() view returns (bytes32)",
    "function LEAGUE_ROLE() view returns (bytes32)",
  ], deployer);

  const dec      = await EURC.decimals();
  const clubRole = await registry.CLUB_ROLE();
  const regRole  = await registry.REGISTRAR_ROLE();
  const escClub  = await escrow.CLUB_ROLE();
  const escLeague = await escrow.LEAGUE_ROLE();

  for (const [label, signer] of [["deployer", deployer], ["club", club]] as const) {
    const bal = await EURC.balanceOf(signer.address);
    console.log(`\n── ${label} (${signer.address}) ──`);
    console.log(`  EURC balance:      ${ethers.formatUnits(bal, dec)}`);
    console.log(`  registry.CLUB:     ${await registry.hasRole(clubRole, signer.address)}`);
    console.log(`  registry.REGISTRAR:${await registry.hasRole(regRole, signer.address)}`);
    console.log(`  escrow.CLUB:       ${await escrow.hasRole(escClub, signer.address)}`);
    console.log(`  escrow.LEAGUE:     ${await escrow.hasRole(escLeague, signer.address)}`);
  }
}
main().catch(console.error);
