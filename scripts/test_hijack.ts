import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  const [deployer, club, hijacker] = await ethers.getSigners();

  const REGISTRY = "0xAe7e07e3623448A918198DDF68D0C788A9c86636";
  const WINDOW   = "0xEE2E27e68C3425831964F4333BB252CEdf4F56b0";
  const ESCROW   = "0xEf74E315296B65ffCF04e66B96cc1Ffa35CBeDCD";
  const DEAL     = "0x715651035d9a5e5d455263AA468Adce0eaA9519a";
  const EURC     = "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a";
  const MEDICAL  = ethers.keccak256(ethers.toUtf8Bytes("medical_" + Date.now() + "_" + Math.random()));
  const MED_HASH = ethers.keccak256(ethers.toUtf8Bytes("deal_medical_" + Date.now()));
  const HIJ_MED  = ethers.keccak256(ethers.toUtf8Bytes("hijack_medical_" + Date.now()));

  const playerWallet = ethers.Wallet.createRandom().connect(ethers.provider);

  const registry = new ethers.Contract(REGISTRY, [
    "function totalPlayers() view returns (uint256)",
    "function verifyPlayer(uint256) external",
    "function setMedicalClearance(uint256,bytes32) external",
    "function setPlayerWallet(uint256,address) external",
    "function grantRole(bytes32,address) external",
    "function hasRole(bytes32,address) view returns (bool)",
    "function CLUB_ROLE() view returns (bytes32)",
    "function REGISTRAR_ROLE() view returns (bytes32)",
    "function registrationFee() view returns (uint256)",
  ], deployer);
  const registryClub = new ethers.Contract(REGISTRY, [
    "function registerPlayer(string,string,string,uint256,uint256,string,bytes32) external payable returns (uint256)",
    "function registrationFee() view returns (uint256)",
  ], club);
  const window_ = new ethers.Contract(WINDOW, [
    "function isWindowOpen() view returns (bool)",
    "function totalWindows() view returns (uint256)",
    "function ADMIN_ROLE() view returns (bytes32)",
    "function hasRole(bytes32,address) view returns (bool)",
    "function grantRole(bytes32,address) external",
    "function scheduleWindow(string,uint256,uint256,uint8) external returns (uint256)",
    "function advanceActiveWindow() external",
  ], deployer);
  const escrow = new ethers.Contract(ESCROW, [
    "function grantRole(bytes32,address) external",
    "function hasRole(bytes32,address) view returns (bool)",
    "function CLUB_ROLE() view returns (bytes32)",
    "function LEAGUE_ROLE() view returns (bytes32)",
    "function approveToken(address) external",
    "function isTokenApproved(address) view returns (bool)",
    "function totalOffers() view returns (uint256)",
  ], deployer);
  const escrowClub = new ethers.Contract(ESCROW, [
    "function createOffer(uint256,address,uint256,uint256,address,uint256,address,uint256,(string,uint256,bool,bool)[]) external returns (uint256)",
    "function totalOffers() view returns (uint256)",
    "function acceptBid(uint256,address) external",
  ], club);
  const escrowDep = new ethers.Contract(ESCROW, [
    "function submitBid(uint256,uint256,uint256,address,uint256,address,uint256,address,uint256,uint256[],uint256[]) external",
    "function processExpiry(uint256) external",
  ], deployer);
  const escrowHijacker = new ethers.Contract(ESCROW, [
    "function submitHijackBid(uint256,uint256,uint256,address,uint256) external",
  ], hijacker);
  const dealDep = new ethers.Contract(DEAL, [
    "function totalDeals() view returns (uint256)",
    "function getDealView(uint256) view returns (tuple(bool exists, address sellingClub, address buyingClub, address paymentToken, uint256 transferFee, uint256 minimumHijackIncrementBps, uint8 state, uint256 stateDeadline))",
    "function submitMedical(uint256,uint8,bytes32) external",
    "function setTimer(uint8,uint256) external",
    "function hijackWindow() view returns (uint256)",
    "function consentWindow() view returns (uint256)",
    "function ADMIN_ROLE() view returns (bytes32)",
    "function hasRole(bytes32,address) view returns (bool)",
    "function getHijackBid(uint256) view returns (tuple(address buyingClub, uint256 transferFee, uint256 buyerAgentBps, address buyerAgent, uint256 signingBonusMonths, uint256 depositedAt, bool exists))",
  ], deployer);
  const dealClub = new ethers.Contract(DEAL, [
    "function acceptHijackBid(uint256) external",
  ], club);
  const dealPlayer = new ethers.Contract(DEAL, [
    "function consentToTransfer(uint256) external",
  ], playerWallet);
  const dealHijacker = new ethers.Contract(DEAL, [
    "function fundDeal(uint256) external",
    "function submitMedical(uint256,uint8,bytes32) external",
  ], hijacker);
  const eurc = new ethers.Contract(EURC, [
    "function approve(address,uint256) external returns (bool)",
    "function balanceOf(address) view returns (uint256)",
  ], deployer);
  const eurcHijacker = new ethers.Contract(EURC, [
    "function approve(address,uint256) external returns (bool)",
    "function balanceOf(address) view returns (uint256)",
  ], hijacker);

  // ── Setup ──────────────────────────────────────────────────────────────────
  console.log("=== SETUP ===");
  console.log("  deployer:", deployer.address);
  console.log("  club:    ", club.address);
  console.log("  hijacker:", hijacker.address);

  const clubRole  = await registry.CLUB_ROLE();
  const regRole   = await registry.REGISTRAR_ROLE();
  const escClub   = await escrow.CLUB_ROLE();
  const escLeague = await escrow.LEAGUE_ROLE();
  const winAdmin  = await window_.ADMIN_ROLE();

  if (!await registry.hasRole(clubRole, club.address))       { await (await registry.grantRole(clubRole, club.address)).wait();      console.log("  registry.CLUB → club"); }
  if (!await registry.hasRole(clubRole, deployer.address))   { await (await registry.grantRole(clubRole, deployer.address)).wait();  console.log("  registry.CLUB → deployer"); }
  if (!await registry.hasRole(regRole,  deployer.address))   { await (await registry.grantRole(regRole,  deployer.address)).wait();  console.log("  registry.REGISTRAR → deployer"); }
  if (!await escrow.hasRole(escClub, club.address))          { await (await escrow.grantRole(escClub, club.address)).wait();         console.log("  escrow.CLUB → club"); }
  if (!await escrow.hasRole(escClub, deployer.address))      { await (await escrow.grantRole(escClub, deployer.address)).wait();     console.log("  escrow.CLUB → deployer"); }
  if (!await escrow.hasRole(escLeague, deployer.address))    { await (await escrow.grantRole(escLeague, deployer.address)).wait();   console.log("  escrow.LEAGUE → deployer"); }
  if (!await window_.hasRole(winAdmin, deployer.address))    { await (await window_.grantRole(winAdmin, deployer.address)).wait();   console.log("  window.ADMIN → deployer"); }
  if (!await escrow.hasRole(escClub, hijacker.address))      { await (await escrow.grantRole(escClub, hijacker.address)).wait();     console.log("  escrow.CLUB → hijacker"); }
  if (!await escrow.isTokenApproved(EURC))                   { await (await escrow.approveToken(EURC)).wait();                       console.log("  EURC approved"); }

  // Timers: 15s each
  await (await dealDep.setTimer(0, 15)).wait(); // consentWindow
  await (await dealDep.setTimer(1, 15)).wait(); // medicalWindow
  await (await dealDep.setTimer(2, 60)).wait(); // hijackWindow
  await (await dealDep.setTimer(3, 15)).wait(); // disputeWindow
  await (await dealDep.setTimer(5, 15)).wait(); // fundingWindow
  console.log("  hijackWindow:", (await dealDep.hijackWindow()).toString(), "s");
  console.log("  consentWindow:", (await dealDep.consentWindow()).toString(), "s");

  // Transfer window
  if (!(await window_.isWindowOpen())) {
    const block = await ethers.provider.getBlock("latest");
    const ts    = BigInt(block!.timestamp);
    await (await window_.scheduleWindow("Test", ts + 120n, ts + BigInt(30*86400), 0)).wait();
    console.log("  Window scheduled, waiting 125s...");
    await new Promise(r => setTimeout(r, 125000));
    await (await window_.advanceActiveWindow()).wait();
    await (await window_.advanceActiveWindow()).wait();
  }
  console.log("  isWindowOpen:", await window_.isWindowOpen());

  // ── Register player ────────────────────────────────────────────────────────
  console.log("\n=== FLOW ===");
  const block   = await ethers.provider.getBlock("latest");
  const blockTs = BigInt(block!.timestamp);
  const name    = "Hijack" + Date.now().toString().slice(-4);
  const expiry  = blockTs + BigInt(365 * 86400);
  const salary  = ethers.parseUnits("1", 6); // €1/week
  const fee     = await registryClub.registrationFee();

  console.log("[1] Registering:", name, "(salary €1/week for signing bonus math)");
  await (await registryClub.registerPlayer(name, "ST", "Brazilian", expiry, salary, "", ethers.ZeroHash, { value: fee })).wait();
  const playerId = await registry.totalPlayers();
  console.log("  Player #" + playerId.toString());

  console.log("[2] Verify + wallet + medical...");
  await (await registry.verifyPlayer(playerId)).wait();
  // Fund player wallet with USDC for gas
  const usdcContract = new ethers.Contract("0x3600000000000000000000000000000000000000", [
    "function transfer(address,uint256) external returns (bool)",
  ], deployer);
  await (await usdcContract.transfer(playerWallet.address, ethers.parseUnits("1", 6))).wait();
  await (await registry.setPlayerWallet(playerId, playerWallet.address)).wait();
  await (await registry.setMedicalClearance(playerId, MEDICAL)).wait();
  console.log("  Done — player wallet:", playerWallet.address);

  // Use deployer as agent, club as sell-on recipient
  const sellerAgent = deployer.address;
  const buyerAgent  = deployer.address;
  const sellOnRecip = club.address;

  console.log("[3] Creating offer: €12 asking, 5% sell-on, 2% seller agent, performance add-on €1 to player...");
  // addOns as positional arrays, not objects
  // AddOn tuple: [description, amount, toPlayer, triggered]
  const addOns = [
    ["Goal bonus", ethers.parseUnits("1", 6), true, false]
  ];
  await (await escrowClub.createOffer(
    playerId, EURC,
    ethers.parseUnits("12", 6),  // €12 asking
    500,  sellOnRecip,           // 5% sell-on
    200,  sellerAgent,           // 2% seller agent
    100,                         // 1% min hijack increment
    addOns
  )).wait();
  const offerId = await escrowClub.totalOffers();
  console.log("  Offer #" + offerId.toString());

  console.log("[4] Deployer bids €10 with 2% buyer agent + 2 months signing bonus...");
  const transferFee = ethers.parseUnits("10", 6);
  const instDue     = blockTs + BigInt(30 * 24 * 3600);
  await (await escrowDep.submitBid(
    offerId, transferFee,
    500, sellOnRecip,   // sell-on pass-through
    200, sellerAgent,   // seller agent
    200, buyerAgent,    // buyer agent
    2,                  // 2 months signing bonus
    [transferFee], [instDue]
  )).wait();

  console.log("[5] Club accepts bid...");
  await (await escrowClub.acceptBid(offerId, deployer.address)).wait();
  const dealId = await dealDep.totalDeals();
  let d = await dealDep.getDealView(dealId);
  console.log("  Deal #" + dealId.toString() + " state:", d.state, "(5=AWAITING_PLAYER_CONSENT)");

  console.log("[6] Player consents...");
  await (await dealPlayer.consentToTransfer(dealId)).wait();
  d = await dealDep.getDealView(dealId);
  console.log("  State:", d.state, "(6=AWAITING_TRANSFER_MEDICAL)");

  console.log("[7] Deployer submits medical (PASSED) → HIJACK_WINDOW...");
  await (await dealDep.submitMedical(dealId, 1, MED_HASH)).wait();
  d = await dealDep.getDealView(dealId);
  console.log("  State:", d.state, "(9=HIJACK_WINDOW)");
  console.log("  Original fee: €" + ethers.formatUnits(d.transferFee, 6));
  console.log("  Min hijack increment bps:", d.minimumHijackIncrementBps.toString());

  // ── HIJACK ─────────────────────────────────────────────────────────────────
  console.log("\n=== HIJACK ===");
  const minHijackFee = d.transferFee + (d.transferFee * d.minimumHijackIncrementBps / 10000n);
  const hijackFee    = minHijackFee + ethers.parseUnits("1", 6); // €1 above minimum
  console.log("[H1] Hijacker bids €" + ethers.formatUnits(hijackFee, 6) + " (min was €" + ethers.formatUnits(minHijackFee, 6) + ")");

  await (await eurcHijacker.approve(ESCROW, hijackFee)).wait();
  await (await escrowHijacker.submitHijackBid(
    dealId, hijackFee,
    0, ethers.ZeroAddress, // no buyer agent
    0                      // no signing bonus
  )).wait();

  console.log("  Hijack bid submitted — €" + ethers.formatUnits(hijackFee, 6));

  console.log("[H2] Selling club accepts hijack bid...");
  await (await dealClub.acceptHijackBid(dealId)).wait();
  d = await dealDep.getDealView(dealId);
  console.log("  State:", d.state, "(10=AWAITING_HIJACK_CONSENT)");

  console.log("[H3] Player consents to hijack...");
  await (await dealPlayer.consentToTransfer(dealId)).wait();
  d = await dealDep.getDealView(dealId);
  console.log("  State:", d.state, "(11=AWAITING_HIJACK_MEDICAL)");

  console.log("[H4] Hijacker submits medical (PASSED)...");
  await (await dealHijacker.submitMedical(dealId, 1, HIJ_MED)).wait();
  d = await dealDep.getDealView(dealId);
  console.log("  State:", d.state, "(13=FUNDING_PENDING)");

  console.log("[H5] Hijacker funds deal...");
  console.log("  Hijacker EURC:", ethers.formatUnits(await eurcHijacker.balanceOf(hijacker.address), 6));
  // Hijack funds already in DealEscrow from submitHijackBid — fundDeal settles distribution
  await (await eurcHijacker.approve(DEAL, hijackFee)).wait();
  await (await dealHijacker.fundDeal(dealId)).wait();
  d = await dealDep.getDealView(dealId);
  console.log("  State:", d.state, "(14=FUNDED)");

  console.log("\n✓ Hijack simulation complete!");
  console.log("  Original buyer (deployer) refunded via claimable");
  console.log("  Selling club gets €" + ethers.formatUnits(hijackFee, 6) + " (minus fees)");
  console.log("  Sell-on clause active for future transfers");
  console.log("  Performance add-on (Goal bonus €1) claimable when triggered");
  console.log("\nDeployer EURC:", ethers.formatUnits(await eurc.balanceOf(deployer.address), 6));
  console.log("Hijacker EURC:", ethers.formatUnits(await eurcHijacker.balanceOf(hijacker.address), 6));
}
main().catch(console.error);
