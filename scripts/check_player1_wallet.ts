import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  ethers.provider.pollingInterval = 15000;

  const REGISTRY = "0x21962C5548aeD0Ca83c8a1Bf051FE221CB9De4f9";
  const registry = await ethers.getContractAt("PlayerRegistry", REGISTRY);

  const player = await registry.getPlayer(1);
  const wallet = player.playerWallet;
  console.log("Player 1 wallet:", wallet);

  if (wallet === ethers.ZeroAddress) {
    console.log("No wallet assigned — nothing to check.");
    return;
  }

  const CLUB_ROLE = await registry.CLUB_ROLE();
  const REGISTRAR_ROLE = await registry.REGISTRAR_ROLE();
  const ADMIN_ROLE = await registry.ADMIN_ROLE();
  const LEAGUE_ROLE = await registry.LEAGUE_ROLE();

  const [hasClub, hasRegistrar, hasAdmin, hasLeague, hasDefaultAdmin] = await Promise.all([
    registry.hasRole(CLUB_ROLE, wallet),
    registry.hasRole(REGISTRAR_ROLE, wallet),
    registry.hasRole(ADMIN_ROLE, wallet),
    registry.hasRole(LEAGUE_ROLE, wallet),
    registry.hasRole(ethers.ZeroHash, wallet),
  ]);
  console.log("Holds CLUB_ROLE:", hasClub);
  console.log("Holds REGISTRAR_ROLE:", hasRegistrar);
  console.log("Holds ADMIN_ROLE:", hasAdmin);
  console.log("Holds LEAGUE_ROLE:", hasLeague);
  console.log("Holds DEFAULT_ADMIN_ROLE:", hasDefaultAdmin);
  const conflicted = hasClub || hasRegistrar || hasAdmin || hasLeague || hasDefaultAdmin;
  console.log(conflicted ? "\n⚠️  CONFLICT FOUND — needs remediation too" : "\n✅ No conflict — player 1's wallet is clean");
}

main().catch(console.error);
