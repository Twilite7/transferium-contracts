const { ethers } = require("./node_modules/ethers");
const { readFileSync } = require("fs");

async function main() {
  const env     = readFileSync(".env", "utf8");
  const PRIVKEY = env.match(/DEPLOYER_PRIVATE_KEY=(.+)/)?.[1]?.trim();
  const RPC     = "https://rpc.testnet.arc.network";

  const provider = new ethers.JsonRpcProvider(RPC, {
    chainId: 5042002, name: "arc"
  }, { staticNetwork: true, pollingInterval: 4000 });

  const wallet = new ethers.Wallet(PRIVKEY, provider);

  const iface = new ethers.Interface([
    "function hasRole(bytes32,address) view returns (bool)",
    "function grantRole(bytes32,address)",
    "function CLUB_ROLE() view returns (bytes32)",
    "function REGISTRAR_ROLE() view returns (bytes32)",
  ]);

  const REGISTRY = "0x1aFCB3929E653ACdaCfDeAf2CfcfF083B194F962";

  const clubRoleResult = await provider.call({ to: REGISTRY, data: iface.encodeFunctionData("CLUB_ROLE", []) });
  const CLUB_ROLE      = iface.decodeFunctionResult("CLUB_ROLE", clubRoleResult)[0];

  const regRoleResult  = await provider.call({ to: REGISTRY, data: iface.encodeFunctionData("REGISTRAR_ROLE", []) });
  const REGISTRAR_ROLE = iface.decodeFunctionResult("REGISTRAR_ROLE", regRoleResult)[0];

  const hasClubResult = await provider.call({ to: REGISTRY, data: iface.encodeFunctionData("hasRole", [CLUB_ROLE, wallet.address]) });
  const hasClub       = iface.decodeFunctionResult("hasRole", hasClubResult)[0];

  const hasRegResult  = await provider.call({ to: REGISTRY, data: iface.encodeFunctionData("hasRole", [REGISTRAR_ROLE, wallet.address]) });
  const hasRegistrar  = iface.decodeFunctionResult("hasRole", hasRegResult)[0];

  console.log("Deployer:          ", wallet.address);
  console.log("Has CLUB_ROLE:     ", hasClub);
  console.log("Has REGISTRAR_ROLE:", hasRegistrar);

  if (!hasClub) {
    console.log("Granting CLUB_ROLE...");
    const tx = await wallet.sendTransaction({
      to: REGISTRY,
      data: iface.encodeFunctionData("grantRole", [CLUB_ROLE, wallet.address]),
      gasLimit: 100000,
    });
    console.log("Tx:", tx.hash);
    await tx.wait();
    console.log("CLUB_ROLE granted.");
  }

  if (!hasRegistrar) {
    console.log("Granting REGISTRAR_ROLE...");
    const tx = await wallet.sendTransaction({
      to: REGISTRY,
      data: iface.encodeFunctionData("grantRole", [REGISTRAR_ROLE, wallet.address]),
      gasLimit: 100000,
    });
    console.log("Tx:", tx.hash);
    await tx.wait();
    console.log("REGISTRAR_ROLE granted.");
  }

  console.log("Done.");
}

main().catch(e => { console.error(e.shortMessage ?? e.message); process.exit(1); });
