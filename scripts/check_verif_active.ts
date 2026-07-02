import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  const registry = new ethers.Contract(
    "0xFA8dCb6f0DB181DD9400888a1e0874Ebba94D7bA",
    [
      "function verificationActive(uint256) view returns (bool)",
      "function getPlayer(uint256) view returns (tuple(string,string,string,uint40,uint40,uint96,bytes32,bytes32,address,address,uint128,uint128,string,bool,bool,bool,bool))",
    ],
    ethers.provider
  );

  try {
    const active = await registry.verificationActive(1);
    console.log("verificationActive(1):", active);
  } catch (e: any) {
    console.log("verificationActive REVERTED:", e.message?.slice(0, 120));
  }

  try {
    const raw = await registry.getPlayer(1);
    console.log("getPlayer succeeded, tuple length:", raw.length);
  } catch (e: any) {
    console.log("getPlayer REVERTED:", e.message?.slice(0, 120));
  }
}

main().catch(e => { console.error(e); process.exit(1); });
