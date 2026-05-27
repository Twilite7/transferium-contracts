import { network } from "hardhat";
async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();
  const REGISTRY = "0x983B1e2e39C534762841932b526D3f145110b38A";
  const registry = new ethers.Contract(REGISTRY, [
    "function registrationFee() view returns (uint256)",
    "function registerPlayer(string,string,string,uint256,uint256,string,bytes32) external payable returns (uint256)",
  ], deployer);
  const fee = await registry.registrationFee();
  console.log("registrationFee:", fee.toString(), "=", ethers.formatUnits(fee, 6), "USDC");
  // Check deployer native balance
  const bal = await ethers.provider.getBalance(deployer.address);
  console.log("deployer native balance:", ethers.formatUnits(bal, 6));
}
main().catch(console.error);
