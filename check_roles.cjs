const { ethers } = require("./node_modules/ethers");
const { readFileSync } = require("fs");

async function main() {
  const env     = readFileSync(".env", "utf8");
  const PRIVKEY = env.match(/DEPLOYER_PRIVATE_KEY=(.+)/)?.[1]?.trim();
  const RPC     = "https://rpc.testnet.arc.network";

  const provider = new ethers.JsonRpcProvider(RPC, {
    chainId: 5042002,
    name: "arc"
  }, { staticNetwork: true, pollingInterval: 4000 });

  const wallet = new ethers.Wallet(PRIVKEY, provider);
  console.log("Wallet:", wallet.address);

  const abi = [
    "function hasRole(bytes32,address) view returns (bool)",
    "function grantRole(bytes32,address)",
    "function CLUB_ROLE() view returns (bytes32)",
    "function REGISTRAR_ROLE() view returns (bytes32)",
    "function registrationFee() view returns (uint256)",
  ];

  const registry = new ethers.Contract(
    "0x1aFCB3929E653ACdaCfDeAf2CfcfF083B194F962",
    abi,
    wallet
  );

  const CLUB_ROLE = await registry.CLUB_ROLE();
  console.log("CLUB_ROLE:", CLUB_ROLE);

  const hasClub = await registry.hasRole(CLUB_ROLE, wallet.address);
  console.log("Has CLUB_ROLE:", hasClub);

  if (!hasClub) {
    console.log("Granting CLUB_ROLE...");
    const tx = await registry.grantRole(CLUB_ROLE, wallet.address, { gasLimit: 100000 });
    console.log("Tx:", tx.hash);
    await tx.wait();
    console.log("Done.");
  }
}

main().catch(e => { console.error(e.message ?? e); process.exit(1); });
