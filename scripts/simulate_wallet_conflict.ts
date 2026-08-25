import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  ethers.provider.pollingInterval = 15000;

  const REGISTRY = "0x21962C5548aeD0Ca83c8a1Bf051FE221CB9De4f9";
  const PLAYER_ID = 2;
  const TARGET_WALLET = "0x14F94f8bf5223C2a8BA90092c0F97dfF834C8Bba";
  const CLUB = "0xf6ee621fcfcee360bf3bba8707144a58b0028f85"; // FC Barcelona, per snapshot

  const registry = await ethers.getContractAt("PlayerRegistry", REGISTRY);

  const REGISTRAR_ROLE = await registry.REGISTRAR_ROLE();
  const CLUB_ROLE = await registry.CLUB_ROLE();
  const ADMIN_ROLE = await registry.ADMIN_ROLE();
  const LEAGUE_ROLE = await registry.LEAGUE_ROLE();
  const DEFAULT_ADMIN_ROLE = ethers.ZeroHash;

  const [hasRegistrar, hasClub, hasAdmin, hasLeague, hasDefaultAdmin] = await Promise.all([
    registry.hasRole(REGISTRAR_ROLE, TARGET_WALLET),
    registry.hasRole(CLUB_ROLE, TARGET_WALLET),
    registry.hasRole(ADMIN_ROLE, TARGET_WALLET),
    registry.hasRole(LEAGUE_ROLE, TARGET_WALLET),
    registry.hasRole(DEFAULT_ADMIN_ROLE, TARGET_WALLET),
  ]);
  console.log(`Wallet ${TARGET_WALLET} currently holds:`);
  console.log("  REGISTRAR_ROLE:", hasRegistrar);
  console.log("  CLUB_ROLE:", hasClub);
  console.log("  ADMIN_ROLE:", hasAdmin);
  console.log("  LEAGUE_ROLE:", hasLeague);
  console.log("  DEFAULT_ADMIN_ROLE:", hasDefaultAdmin);

  const signers = await ethers.getSigners();
  console.log("\nAvailable signers:", signers.map((s: any) => s.address));
  const clubSigner = signers.find((s: any) => s.address.toLowerCase() === CLUB.toLowerCase());
  if (!clubSigner) {
    console.log("❌ No configured signer matches the club address", CLUB, "— cannot simulate as this club.");
    return;
  }
  console.log(`\nSimulating setPlayerWallet(${PLAYER_ID}, ${TARGET_WALLET}) as club ${CLUB} (real signer)...`);
  try {
    await registry.connect(clubSigner).setPlayerWallet.staticCall(PLAYER_ID, TARGET_WALLET);
    console.log("❌ SIMULATION SUCCEEDED — the contract WOULD accept this wallet. This is bad.");
  } catch (e: any) {
    console.log("✅ SIMULATION REVERTED — the contract rejects this wallet.");
    console.log("   Revert reason:", e.reason || e.shortMessage || e.message?.slice(0, 200));
  }
}

main().catch(console.error);
