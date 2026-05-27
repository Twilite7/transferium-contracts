import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  const registry = new ethers.Contract(
    "0xbE8d243C435796ee8f716CE34B5f76866E909f64",
    [
      "function CLUB_ROLE() view returns (bytes32)",
      "event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender)",
      "event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender)",
    ],
    ethers.provider
  );
  const CLUB_ROLE = await registry.CLUB_ROLE();
  const tip = await ethers.provider.getBlockNumber();
  const CHUNK = 9000;
  const START = 43526900;
  const granted = [], revoked = [];
  for (let from = START; from <= tip; from += CHUNK) {
    const to = Math.min(from + CHUNK - 1, tip);
    const g = await registry.queryFilter(registry.filters.RoleGranted(CLUB_ROLE, null, null), from, to);
    const r = await registry.queryFilter(registry.filters.RoleRevoked(CLUB_ROLE, null, null), from, to);
    granted.push(...g); revoked.push(...r);
  }
  console.log("Granted:", granted.map((e: any) => ({ block: e.blockNumber, account: e.args.account })));
  console.log("Revoked:", revoked.map((e: any) => ({ block: e.blockNumber, account: e.args.account })));
}
main().catch(console.error);
