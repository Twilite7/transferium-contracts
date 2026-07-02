import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  const registry = await ethers.getContractAt(
    "PlayerRegistry",
    "0x2bc403A55Bc895AbaD40F912eE43a01D6Aad8767"
  );

  const PLAYER_WALLET = "PASTE_PLAYER_WALLET_ADDRESS_HERE";

  const pid = await registry.walletToPlayer(PLAYER_WALLET);
  console.log("walletToPlayer:", pid.toString(), pid > 0n ? "(assigned)" : "(unassigned — setPlayerWallet was never called for this address)");

  if (pid > 0n) {
    const raw = await registry.getPlayer(pid);
    console.log("Player name:", raw.name);
    console.log("Player wallet on record:", raw.playerWallet);
  }
}

main().catch(console.error);
