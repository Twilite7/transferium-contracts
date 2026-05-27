import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();
  const [deployer, club] = await ethers.getSigners();

  const REGISTRY = "0xAe7e07e3623448A918198DDF68D0C788A9c86636";
  const WINDOW   = "0xEE2E27e68C3425831964F4333BB252CEdf4F56b0";
  const ESCROW   = "0xEf74E315296B65ffCF04e66B96cc1Ffa35CBeDCD";
  const DEAL     = "0x715651035d9a5e5d455263AA468Adce0eaA9519a";
  const EURC     = "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a";
  const MEDICAL  = ethers.keccak256(ethers.toUtf8Bytes("medical_" + Date.now() + "_" + Math.random()));
  const MED_HASH = ethers.keccak256(ethers.toUtf8Bytes("deal_medical_" + Date.now()));

  const playerWallet = ethers.Wallet.createRandom().connect(ethers.provider);

  const registry = new ethers.Contract(REGISTRY, [
    "function totalPlayers() view returns (uint256)",
    "function verifyPlayer(uint256) external",
    "function setMedicalClearance(uint256,bytes32) external",
    "function setPlayerWallet(uint256,address) external",
  ], deployer);
  const registryClub = new ethers.Contract(REGISTRY, [
    "function registerPlayer(string,string,string,uint256,uint256,string,bytes32) external payable returns (uint256)",
    "function registrationFee() view returns (uint256)",
  ], club);
  const escrowClub = new ethers.Contract(ESCROW, [
    "function createOffer(uint256,address,uint256,uint256,address,uint256,address,uint256,(string,uint256,bool,bool)[]) external returns (uint256)",
    "function totalOffers() view returns (uint256)",
    "function acceptBid(uint256,address) external",
  ], club);
  const escrowDep = new ethers.Contract(ESCROW, [
    "function submitBid(uint256,uint256,uint256,address,uint256,address,uint256,address,uint256,uint256[],uint256[]) external",
    "function processExpiry(uint256) external",
  ], deployer);
  const dealDep = new ethers.Contract(DEAL, [
    "function totalDeals() view returns (uint256)",
    "function getDealView(uint256) view returns (tuple(bool exists, address sellingClub, address buyingClub, address paymentToken, uint256 transferFee, uint256 minimumHijackIncrementBps, uint8 state, uint256 stateDeadline))",
    "function fundDeal(uint256) external",
    "function submitMedical(uint256,uint8,bytes32) external",
  ], deployer);
  const dealPlayer = new ethers.Contract(DEAL, [
    "function consentToTransfer(uint256) external",
  ], playerWallet);
  const eurc = new ethers.Contract(EURC, [
    "function approve(address,uint256) external returns (bool)",
    "function balanceOf(address) view returns (uint256)",
  ], deployer);

  const block   = await ethers.provider.getBlock("latest");
  const blockTs = BigInt(block!.timestamp);
  const name    = "FlowTest" + Date.now().toString().slice(-4);
  const expiry  = blockTs + BigInt(365 * 86400);
  const salary  = ethers.parseUnits("5000", 6);
  const fee     = await registryClub.registrationFee();

  // Use small amounts that fit deployer's 80 EURC balance
  const askingPrice = ethers.parseUnits("60", 6);  // €60 asking
  const transferFee = ethers.parseUnits("50", 6);  // €50 bid
  const instDue     = blockTs + BigInt(30 * 24 * 3600);

  console.log("[1] Registering:", name);
  await (await registryClub.registerPlayer(name, "CM", "English", expiry, salary, "", ethers.ZeroHash, { value: fee })).wait();
  const playerId = await registry.totalPlayers();
  console.log("  Player #" + playerId.toString());

  console.log("[2] Verify + wallet + medical...");
  await (await registry.verifyPlayer(playerId)).wait();
  await (await registry.setPlayerWallet(playerId, playerWallet.address)).wait();
  await (await registry.setMedicalClearance(playerId, MEDICAL)).wait();
  console.log("  Done");

  console.log("[3] Creating offer (€60 asking)...");
  await (await escrowClub.createOffer(
    playerId, EURC, askingPrice,
    0, ethers.ZeroAddress, 0, ethers.ZeroAddress, 100, []
  )).wait();
  const offerId = await escrowClub.totalOffers();
  console.log("  Offer #" + offerId.toString());

  console.log("[4] Submitting bid (€50)...");
  await (await escrowDep.submitBid(
    offerId, transferFee,
    0, ethers.ZeroAddress, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress,
    0, [transferFee], [instDue]
  )).wait();

  console.log("[5] Accepting bid...");
  await (await escrowClub.acceptBid(offerId, deployer.address)).wait();
  const dealId = await dealDep.totalDeals();
  let d = await dealDep.getDealView(dealId);
  console.log("  Deal #" + dealId.toString() + " state:", d.state, "(expect 5)");

  console.log("[6] Player consent...");
  await (await deployer.sendTransaction({ to: playerWallet.address, value: ethers.parseEther("0.01") })).wait();
  await (await dealPlayer.consentToTransfer(dealId)).wait();
  d = await dealDep.getDealView(dealId);
  console.log("  State:", d.state, "(expect 6)");

  console.log("[7] Submit medical (PASSED)...");
  await (await dealDep.submitMedical(dealId, 1, MED_HASH)).wait();
  d = await dealDep.getDealView(dealId);
  console.log("  State:", d.state, "(expect 9), deadline:", d.stateDeadline.toString());

  console.log("[8] Waiting 20s for hijack window...");
  await new Promise(r => setTimeout(r, 20000));

  console.log("[9] processExpiry → FUNDING_PENDING...");
  await (await escrowDep.processExpiry(dealId)).wait();
  d = await dealDep.getDealView(dealId);
  console.log("  State:", d.state, "(expect 13)");

  console.log("[10] Funding deal...");
  const bal = await eurc.balanceOf(deployer.address);
  console.log("  Deployer EURC:", ethers.formatUnits(bal, 6));
  await (await eurc.approve(DEAL, transferFee)).wait();
  await (await dealDep.fundDeal(dealId)).wait();
  d = await dealDep.getDealView(dealId);
  console.log("  State:", d.state, "(expect 14=FUNDED)");

  console.log("\n✓ Full transfer flow completed!");
}
main().catch(console.error);
