import { network } from "hardhat";
import addresses from "../deployments/addresses.json";

/**
 * Transferium Protocol — Schedule Transfer Window
 *
 * I schedule a transfer window on the TransferWindow contract.
 * Edit the window parameters below before running.
 *
 * Real-world football transfer windows:
 * - Summer window: typically June 1 – August 31
 * - January window: typically January 1 – January 31
 */

// ─── Configure these before running ──────────────────────────────────────────

const WINDOW_LABEL = "Summer 2026";

// I set Unix timestamps — use https://www.unixtimestamp.com to convert dates
// Summer 2026: June 1 2026 00:00:00 UTC → August 31 2026 23:59:59 UTC
const WINDOW_OPENS_AT  = 1748736000 + 365 * 24 * 3600; // June 1 2026 00:00:00 UTC
const WINDOW_CLOSES_AT = 1756684799 + 365 * 24 * 3600; // August 31 2026 23:59:59 UTC

// ─────────────────────────────────────────────────────────────────────────────

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();

  console.log("─────────────────────────────────────────");
  console.log("Transferium Protocol — Schedule Window");
  console.log("─────────────────────────────────────────");
  console.log(`Deployer : ${deployer.address}`);
  console.log(`Network  : ${network.name}`);
  console.log(`Label    : ${WINDOW_LABEL}`);
  console.log(`Opens    : ${new Date(WINDOW_OPENS_AT * 1000).toUTCString()}`);
  console.log(`Closes   : ${new Date(WINDOW_CLOSES_AT * 1000).toUTCString()}`);
  console.log("─────────────────────────────────────────\n");

  const now = Math.floor(Date.now() / 1000);

  if (WINDOW_OPENS_AT <= now) {
    console.error("❌ WINDOW_OPENS_AT must be in the future.");
    process.exit(1);
  }

  if (WINDOW_CLOSES_AT <= WINDOW_OPENS_AT) {
    console.error("❌ WINDOW_CLOSES_AT must be after WINDOW_OPENS_AT.");
    process.exit(1);
  }

  const windowAbi = [
    "function scheduleWindow(string calldata label, uint256 opensAt, uint256 closesAt) external returns (uint256)",
    "function getWindow(uint256 windowId) external view returns (tuple(uint256 id, string label, uint256 opensAt, uint256 closesAt, bool exists))",
    "function totalWindows() external view returns (uint256)",
  ];

  const transferWindow = await ethers.getContractAt(
    windowAbi,
    addresses.TransferWindow,
    deployer
  );

  console.log("Scheduling window...");
  const tx = await transferWindow.scheduleWindow(
    WINDOW_LABEL,
    WINDOW_OPENS_AT,
    WINDOW_CLOSES_AT
  );
  const receipt = await tx.wait();

  const iface = new ethers.Interface([
    "event WindowScheduled(uint256 indexed windowId, string label, uint256 opensAt, uint256 closesAt)"
  ]);
  const event = receipt.logs
    .map((log: any) => { try { return iface.parseLog(log); } catch { return null; } })
    .find((e: any) => e?.name === "WindowScheduled");

  const windowId = event?.args?.windowId ?? "unknown";

  console.log(`✅ Window scheduled`);
  console.log(`   Window ID : ${windowId}`);
  console.log(`   Label     : ${WINDOW_LABEL}`);
  console.log(`   Opens     : ${new Date(WINDOW_OPENS_AT * 1000).toUTCString()}`);
  console.log(`   Closes    : ${new Date(WINDOW_CLOSES_AT * 1000).toUTCString()}`);
  console.log(`\nTotal windows scheduled: ${await transferWindow.totalWindows()}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
