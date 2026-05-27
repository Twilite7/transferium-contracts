import { network } from "hardhat";
async function main() {
  const { ethers } = await network.connect();
  const [deployer, club] = await ethers.getSigners();
  const LOAN  = "0x022DfeE75f882489BA63578fc3fcCc05782A470d";
  const EURC  = "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a";
  const loan  = new ethers.Contract(LOAN, [
    "function approveToken(address) external",
    "function isTokenApproved(address) view returns (bool)",
    "function grantRole(bytes32,address) external",
    "function hasRole(bytes32,address) view returns (bool)",
    "function CLUB_ROLE() view returns (bytes32)",
    "function LEAGUE_ROLE() view returns (bytes32)",
  ], deployer);
  const clubRole   = await loan.CLUB_ROLE();
  const leagueRole = await loan.LEAGUE_ROLE();
  if (!await loan.isTokenApproved(EURC))              { await (await loan.approveToken(EURC)).wait();               console.log("EURC approved"); }
  if (!await loan.hasRole(clubRole, club.address))     { await (await loan.grantRole(clubRole, club.address)).wait(); console.log("CLUB → club"); }
  if (!await loan.hasRole(clubRole, deployer.address)) { await (await loan.grantRole(clubRole, deployer.address)).wait(); console.log("CLUB → deployer"); }
  if (!await loan.hasRole(leagueRole, deployer.address)) { await (await loan.grantRole(leagueRole, deployer.address)).wait(); console.log("LEAGUE → deployer"); }
  console.log("LoanEscrow ready");
}
main().catch(console.error);
