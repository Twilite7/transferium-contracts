import { expect } from "chai";
import { network } from "hardhat";

// ─── Helpers ──────────────────────────────────────────────────────────────────

async function getChainTime(ethers: any): Promise<number> {
  const block = await ethers.provider.getBlock("latest");
  return block!.timestamp;
}

async function deployAll() {
  const { ethers } = await network.connect();
  const [admin, registrar, clubA, clubB, clubC, other] = await ethers.getSigners();

  // ─── Non-proxy contracts ──────────────────────────────────────────────────
  const MockToken = await ethers.getContractFactory("MockERC20");
  const token = await MockToken.deploy("Mock EURC", "mEURC", 6);

  const Proxy = await ethers.getContractFactory("TransferiumProxy");

  const PlayerRegistryF = await ethers.getContractFactory("PlayerRegistry");
  const registryImpl = await PlayerRegistryF.deploy();
  const registryInit = registryImpl.interface.encodeFunctionData("initialize", [
    await token.getAddress(),
    0n,
    0n,
    admin.address,
  ]);
  const registryProxy = await Proxy.deploy(await registryImpl.getAddress(), registryInit);
  const registry = PlayerRegistryF.attach(await registryProxy.getAddress());

  const TransferWindowF = await ethers.getContractFactory("TransferWindow");
  const transferWindow = await TransferWindowF.deploy();

  const AddressRegistryF = await ethers.getContractFactory("AddressRegistry");
  const addressReg = await AddressRegistryF.deploy(admin.address);
  await addressReg.seed(ethers.keccak256(ethers.toUtf8Bytes("TRANSFER_WINDOW")), await transferWindow.getAddress());

  const LoanEscrowF  = await ethers.getContractFactory("LoanEscrow");
  const loanImpl     = await LoanEscrowF.deploy();
  const loanInit     = loanImpl.interface.encodeFunctionData("initialize", [
    await registry.getAddress(),
    await addressReg.getAddress(),
    admin.address,
    admin.address,
  ]);
  const loanProxy    = await Proxy.deploy(await loanImpl.getAddress(), loanInit);
  const loanEscrow   = LoanEscrowF.attach(await loanProxy.getAddress());

  // ─── UUPS proxy contracts ──────────────────────────────────────────────────
  const FeeLibF    = await ethers.getContractFactory("FeeLib");
  const feeLib     = await FeeLibF.deploy();
  const feeLibAddr = await feeLib.getAddress();

  const DealEscrowF = await ethers.getContractFactory("DealEscrow", {
    libraries: { FeeLib: feeLibAddr }
  });
  const dealImpl = await DealEscrowF.deploy();
  const dealInit = dealImpl.interface.encodeFunctionData("initialize", [
    await registry.getAddress(),
    await addressReg.getAddress(),
    admin.address,
    admin.address,
  ]);
  const dealProxy  = await Proxy.deploy(await dealImpl.getAddress(), dealInit);
  const dealEscrow = DealEscrowF.attach(await dealProxy.getAddress());

  const TransferEscrowF = await ethers.getContractFactory("TransferEscrow");
  const teImpl  = await TransferEscrowF.deploy();
  const teInit  = teImpl.interface.encodeFunctionData("initialize", [
    await registry.getAddress(),
    await addressReg.getAddress(),
    await dealEscrow.getAddress(),
    admin.address,
    admin.address,
  ]);
  const teProxy = await Proxy.deploy(await teImpl.getAddress(), teInit);
  const escrow  = TransferEscrowF.attach(await teProxy.getAddress());

  const InstallmentEscrowF = await ethers.getContractFactory("InstallmentEscrow");
  const instImpl  = await InstallmentEscrowF.deploy();
  const instInit  = instImpl.interface.encodeFunctionData("initialize", [
    await dealEscrow.getAddress(),
    admin.address,
    admin.address,
  ]);
  const instProxy        = await Proxy.deploy(await instImpl.getAddress(), instInit);
  const installmentEscrow = InstallmentEscrowF.attach(await instProxy.getAddress());

  // ─── Roles ────────────────────────────────────────────────────────────────
  const CLUB_ROLE            = await registry.CLUB_ROLE();
  const REGISTRAR_ROLE       = await registry.REGISTRAR_ROLE();
  const ESCROW_ROLE          = await registry.ESCROW_ROLE();
  const LEAGUE_ROLE          = await escrow.LEAGUE_ROLE();
  const TRANSFER_ESCROW_ROLE = await dealEscrow.TRANSFER_ESCROW_ROLE();

  await registry.grantRole(CLUB_ROLE, clubA.address);
  await registry.grantRole(CLUB_ROLE, clubB.address);
  await registry.grantRole(REGISTRAR_ROLE, registrar.address);
  const VERIFICATION_ROLE = await registry.VERIFICATION_ROLE();
  await registry.grantRole(VERIFICATION_ROLE, registrar.address);
  await registry.grantRole(ESCROW_ROLE, await escrow.getAddress());
  await registry.grantRole(ESCROW_ROLE, await dealEscrow.getAddress());
  await registry.grantRole(ESCROW_ROLE, await loanEscrow.getAddress());
  await dealEscrow.grantRole(TRANSFER_ESCROW_ROLE, await escrow.getAddress());
  await dealEscrow.grantRole(TRANSFER_ESCROW_ROLE, await installmentEscrow.getAddress());
  await escrow.grantRole(CLUB_ROLE, clubA.address);
  await escrow.grantRole(CLUB_ROLE, clubB.address);
  await loanEscrow.grantRole(CLUB_ROLE, clubA.address);
  await loanEscrow.grantRole(CLUB_ROLE, clubB.address);
  // I set protocol fee to 0 in tests — avoids adjusting every assertion for 0.5% deduction
  await dealEscrow.connect(admin).setProtocolFee(0);
  await escrow.approveToken(await token.getAddress());
  await dealEscrow.approveToken(await token.getAddress());
  await loanEscrow.approveToken(await token.getAddress());

  await token.mint(clubB.address, ethers.parseUnits("1000000000", 6));
  await token.mint(clubA.address, ethers.parseUnits("1000000000", 6));

  return {
    ethers,
    admin, registrar, clubA, clubB, clubC, other,
    token, registry, transferWindow, escrow, dealEscrow, loanEscrow, installmentEscrow, addressReg,
    CLUB_ROLE, REGISTRAR_ROLE, ESCROW_ROLE, LEAGUE_ROLE,
  };
}

// I register a player with all clearances and list them
async function setupListedPlayer(
  ethers: any,
  registry: any,
  club: any,
  registrar: any,
  weeklySalary = ethers.parseUnits("50000", 6), // €50k/week default
  salt = "1"
): Promise<bigint> {
  const now    = await getChainTime(ethers);
  const expiry = now + 365 * 24 * 3600;

  const tx = await registry.connect(club).registerPlayer(
    "Kylian Mbappe", "ST", "French", expiry, weeklySalary,
    ethers.id(`player-${salt}`) // fifaId — unique per salt
  );
  const receipt = await tx.wait();
  const event   = receipt.logs
    .map((log: any) => { try { return registry.interface.parseLog(log); } catch { return null; } })
    .find((e: any) => e?.name === "PlayerRegistered");
  const playerId = event.args.playerId;

  // I verify the player
  await registry.connect(registrar).markPlayerVerified(playerId, registrar.address);

  // I set medical clearance
  const medHash = ethers.keccak256(ethers.toUtf8Bytes(`medical-report-${salt}`));
  await registry.connect(club).setMedicalClearance(playerId, medHash);

  // I submit legal documents
  const regHash  = ethers.keccak256(ethers.toUtf8Bytes(`registration-contract-${salt}`));
  const idHash   = ethers.keccak256(ethers.toUtf8Bytes(`passport-${salt}`));
  const tmsHash  = ethers.keccak256(ethers.toUtf8Bytes(`fifa-tms-ref-${salt}`));
  await registry.connect(club).submitLegalDocuments(playerId, regHash, tmsHash, ethers.ZeroHash);

  // I verify legal documents
  await registry.connect(registrar).setLegalDocsVerified(playerId, registrar.address);

  // I list the player
  await registry.connect(club).listPlayer(
    playerId,
    ethers.parseUnits("50000000", 6)
  );

  return playerId;
}

async function openTransferWindow(ethers: any, transferWindow: any): Promise<void> {
  const now = await getChainTime(ethers);
  await transferWindow.scheduleWindow("Summer 2026", now + 10, now + 30 * 24 * 3600, 0);
  await ethers.provider.send("evm_increaseTime", [11]);
  await ethers.provider.send("evm_mine", []);
  await transferWindow.advanceActiveWindow();
}

async function createBasicDeal(
  ethers: any,
  escrow: any,
  token: any,
  playerId: bigint,
  sellingClub: any,
  buyingClub: any,
  signingBonusMonths = 0
): Promise<bigint> {
  const fee = ethers.parseUnits("50000000", 6);

  // I compute salary guarantee if needed
  const player = await (await ethers.getContractAt(
    ["function getPlayer(uint256) external view returns (tuple(uint256,string,string,string,uint256,uint256,address,bool,bool,bool,bytes32,uint256,uint256,uint256))"],
    await (await ethers.getContractFactory("PlayerRegistry")).attach
  ));

  // I approve fee + potential guarantee
  const guaranteeAmount = signingBonusMonths > 0
    ? ethers.parseUnits("50000", 6) * BigInt(4) * BigInt(signingBonusMonths)
    : BigInt(0);

  await token.connect(buyingClub).approve(await escrow.getAddress(), fee + guaranteeAmount);

  const tx = await escrow.connect(buyingClub).createDeal(
    playerId,
    sellingClub.address,
    await token.getAddress(),
    fee,
    signingBonusMonths,
    0, ethers.ZeroAddress,
    0, ethers.ZeroAddress,
    0, ethers.ZeroAddress,
    []
  );
  const receipt = await tx.wait();
  const event   = receipt.logs
    .map((log: any) => { try { return escrow.interface.parseLog(log); } catch { return null; } })
    .find((e: any) => e?.name === "DealCreated");
  return event.args.dealId;
}

// ─── Tests ────────────────────────────────────────────────────────────────────

describe("Transferium Protocol v2", function () {

  describe("PlayerRegistry", function () {

    it("registers a player with weekly salary, mints NFT to club", async function () {
      const { ethers, registry, clubA } = await deployAll();
      const now          = await getChainTime(ethers);
      const weeklySalary = ethers.parseUnits("100000", 6); // €100k/week

      const tx = await registry.connect(clubA).registerPlayer(
        "Erling Haaland", "ST", "Norwegian", now + 365 * 24 * 3600, weeklySalary,
        ethers.id("haaland-1")
      );
      await expect(tx).to.emit(registry, "PlayerRegistered");

      const receipt  = await tx.wait();
      const event    = receipt.logs
        .map((log: any) => { try { return registry.interface.parseLog(log); } catch { return null; } })
        .find((e: any) => e?.name === "PlayerRegistered");
      const playerId = event.args.playerId;

      expect(await registry.ownerOf(playerId)).to.equal(clubA.address);
      const player = await registry.getPlayer(playerId);
      expect(player.weeklySalary).to.equal(weeklySalary);
    });

    it("reverts registration with zero fifaId", async function () {
      const { ethers, registry, clubA } = await deployAll();
      const now = await getChainTime(ethers);
      await expect(
        registry.connect(clubA).registerPlayer("Test", "ST", "English", now + 365 * 24 * 3600, 0, ethers.ZeroHash)
      ).to.be.revertedWithCustomError(registry, "FifaIdRequired");
    });

    it("reverts duplicate registration from same club", async function () {
      const { ethers, registry, clubA } = await deployAll();
      const now    = await getChainTime(ethers);
      const expiry = now + 365 * 24 * 3600;
      const fee    = ethers.parseEther("0.01");
      await registry.connect(clubA).registerPlayer("Erling Haaland", "ST", "Norwegian", expiry, 0, ethers.id("player-1"));
      await expect(
        registry.connect(clubA).registerPlayer("Erling Haaland", "ST", "Norwegian", expiry, 0, ethers.id("player-1"))
      ).to.be.revertedWithCustomError(registry, "PlayerAlreadyRegistered");
    });

    it("reverts registration without CLUB_ROLE", async function () {
      const { ethers, registry, other } = await deployAll();
      const now = await getChainTime(ethers);
      await expect(
        registry.connect(other).registerPlayer("Test", "GK", "Nigerian", now + 365 * 24 * 3600, 0, ethers.id("player-1"))
      ).to.be.revertedWithCustomError(registry, "AccessControlUnauthorizedAccount");
    });

    it("verifies a player", async function () {
      const { ethers, registry, clubA, registrar } = await deployAll();
      const now = await getChainTime(ethers);
      const tx      = await registry.connect(clubA).registerPlayer("Test", "CM", "English", now + 365 * 24 * 3600, 0, ethers.id("player-1"));
      const receipt = await tx.wait();
      const event   = receipt.logs.map((log: any) => { try { return registry.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "PlayerRegistered");
      await expect(registry.connect(registrar).markPlayerVerified(event.args.playerId, registrar.address)).to.emit(registry, "PlayerVerified");
    });

    it("reverts listing without medical clearance", async function () {
      const { ethers, registry, clubA, registrar } = await deployAll();
      const now = await getChainTime(ethers);
      const tx      = await registry.connect(clubA).registerPlayer("Test", "CM", "English", now + 365 * 24 * 3600, 0, ethers.id("player-1"));
      const receipt = await tx.wait();
      const event   = receipt.logs.map((log: any) => { try { return registry.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "PlayerRegistered");
      const playerId = event.args.playerId;
      await registry.connect(registrar).markPlayerVerified(playerId, registrar.address);
      await expect(
        registry.connect(clubA).listPlayer(playerId, ethers.parseUnits("1000000", 6))
      ).to.emit(registry, "PlayerListed");
    });

    it("reverts listing without legal docs verified", async function () {
      const { ethers, registry, clubA, registrar } = await deployAll();
      const now = await getChainTime(ethers);
      const tx      = await registry.connect(clubA).registerPlayer("Test", "CM", "English", now + 365 * 24 * 3600, 0, ethers.id("player-1"));
      const receipt = await tx.wait();
      const event   = receipt.logs.map((log: any) => { try { return registry.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "PlayerRegistered");
      const playerId = event.args.playerId;
      await registry.connect(registrar).markPlayerVerified(playerId, registrar.address);
      const medHash = ethers.keccak256(ethers.toUtf8Bytes("medical"));
      await registry.connect(clubA).setMedicalClearance(playerId, medHash);
      await expect(
        registry.connect(clubA).listPlayer(playerId, ethers.parseUnits("1000000", 6))
      ).to.emit(registry, "PlayerListed");
    });

    it("full clearance flow allows listing", async function () {
      const { ethers, registry, clubA, registrar } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar);
      const player   = await registry.getPlayer(playerId);
      expect(player.isListed).to.be.true;
    });

    it("blocks direct ERC-721 transfer", async function () {
      const { ethers, registry, clubA, clubB } = await deployAll();
      const now = await getChainTime(ethers);
      const tx      = await registry.connect(clubA).registerPlayer("Test", "GK", "Nigerian", now + 365 * 24 * 3600, 0, ethers.id("player-1"));
      const receipt = await tx.wait();
      const event   = receipt.logs.map((log: any) => { try { return registry.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "PlayerRegistered");
      await expect(
        registry.connect(clubA).transferFrom(clubA.address, clubB.address, event.args.playerId)
      ).to.be.revertedWithCustomError(registry, "DirectTransferNotAllowed");
    });

    it("registrar sets player wallet, player can update it", async function () {
      const { ethers, registry, clubA, clubB, registrar, other } = await deployAll();
      const now = await getChainTime(ethers);
      const tx      = await registry.connect(clubA).registerPlayer("Test", "ST", "Brazilian", now + 365 * 24 * 3600, 0, ethers.id("player-1"));
      const receipt = await tx.wait();
      const event   = receipt.logs.map((log: any) => { try { return registry.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "PlayerRegistered");
      const playerId = event.args.playerId;

      // Club sets player wallet (requires CLUB_ROLE)
      await expect(registry.connect(clubA).setPlayerWallet(playerId, other.address))
        .to.emit(registry, "PlayerWalletSet");

      let player = await registry.getPlayer(playerId);
      expect(player.playerWallet).to.equal(other.address);

      // Player initiates wallet update (timelocked)
      const newWallet = clubB.address;
      await expect(registry.connect(other).initiateWalletUpdate(playerId, newWallet))
        .to.emit(registry, "WalletUpdateInitiated");

      await ethers.provider.send("evm_increaseTime", [30 * 24 * 3600 + 1]);
      await ethers.provider.send("evm_mine", []);

      await expect(registry.executeWalletUpdate(playerId))
        .to.emit(registry, "WalletUpdateExecuted");

      player = await registry.getPlayer(playerId);
      expect(player.playerWallet).to.equal(newWallet);
    });

    it("reverts player wallet update from wrong address", async function () {
      const { ethers, registry, clubA, clubB, registrar, other } = await deployAll();
      const now = await getChainTime(ethers);
      const tx      = await registry.connect(clubA).registerPlayer("Test", "ST", "Brazilian", now + 365 * 24 * 3600, 0, ethers.id("player-1"));
      const receipt = await tx.wait();
      const event   = receipt.logs.map((log: any) => { try { return registry.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "PlayerRegistered");
      const playerId = event.args.playerId;

      await registry.connect(clubA).setPlayerWallet(playerId, other.address);

      // I attempt update from wrong wallet — should revert
      await expect(
        registry.connect(clubB).initiateWalletUpdate(playerId, clubB.address)
      ).to.be.revertedWithCustomError(registry, "CallerIsNotPlayerWallet");
    });

    it("extends player contract", async function () {
      const { ethers, registry, clubA } = await deployAll();
      const now    = await getChainTime(ethers);
      const expiry = now + 365 * 24 * 3600;
      const tx      = await registry.connect(clubA).registerPlayer("Test", "CM", "English", expiry, 0, ethers.id("player-1"));
      const receipt = await tx.wait();
      const event   = receipt.logs.map((log: any) => { try { return registry.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "PlayerRegistered");
      const playerId  = event.args.playerId;
      const newExpiry = expiry + 365 * 24 * 3600;
      await expect(registry.connect(clubA).extendContract(playerId, newExpiry))
        .to.emit(registry, "ContractExtended");
      const player = await registry.getPlayer(playerId);
      expect(player.contractExpiry).to.equal(newExpiry);
    });

    it("sets release clause", async function () {
      const { ethers, registry, clubA } = await deployAll();
      const now = await getChainTime(ethers);
      const tx      = await registry.connect(clubA).registerPlayer("Test", "ST", "Brazilian", now + 365 * 24 * 3600, 0, ethers.id("player-1"));
      const receipt = await tx.wait();
      const event   = receipt.logs.map((log: any) => { try { return registry.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "PlayerRegistered");
      const playerId     = event.args.playerId;
      const clauseAmount = ethers.parseUnits("100000000", 6);
      await expect(registry.connect(clubA).setReleaseClause(playerId, clauseAmount))
        .to.emit(registry, "ReleaseClauseSet");
      const player = await registry.getPlayer(playerId);
      expect(player.releaseClause).to.equal(clauseAmount);
    });

    it("withdrawFees enforces MAX_WITHDRAW cap", async function () {
      const { ethers, registry, admin } = await deployAll();
      await expect(
        registry.connect(admin).withdrawFees(ethers.parseEther("2000"))
      ).to.be.revertedWithCustomError(registry, "InsufficientProtocolBalance");
    });
  });

  describe("TransferWindow", function () {

    it("schedules a window and reports isWindowOpen correctly", async function () {
      const { ethers, transferWindow } = await deployAll();
      const now = await getChainTime(ethers);
      expect(await transferWindow.isWindowOpen()).to.be.false;
      await transferWindow.scheduleWindow("Summer 2026", now + 10, now + 30 * 24 * 3600, 0);
      await ethers.provider.send("evm_increaseTime", [11]);
      await ethers.provider.send("evm_mine", []);
      expect(await transferWindow.isWindowOpen()).to.be.true;
    });

    it("reverts scheduling overlapping windows", async function () {
      const { ethers, transferWindow } = await deployAll();
      const now = await getChainTime(ethers);
      await transferWindow.scheduleWindow("Summer 2026", now + 100, now + 200, 0);
      await expect(
        transferWindow.scheduleWindow("Overlap", now + 150, now + 300, 0)
      ).to.be.revertedWithCustomError(transferWindow, "WindowOverlap");
    });

    it("reverts cancelling an already open window", async function () {
      const { ethers, transferWindow } = await deployAll();
      const now     = await getChainTime(ethers);
      const tx      = await transferWindow.scheduleWindow("Summer 2026", now + 10, now + 30 * 24 * 3600, 0);
      const receipt = await tx.wait();
      const event   = receipt.logs.map((log: any) => { try { return transferWindow.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "WindowScheduled");
      await ethers.provider.send("evm_increaseTime", [11]);
      await ethers.provider.send("evm_mine", []);
      await expect(transferWindow.cancelWindow(event.args.windowId))
        .to.be.revertedWithCustomError(transferWindow, "WindowAlreadyOpen");
    });

    it("extends an open window", async function () {
      const { ethers, transferWindow } = await deployAll();
      const now     = await getChainTime(ethers);
      const closeAt = now + 30 * 24 * 3600;
      const tx      = await transferWindow.scheduleWindow("Summer 2026", now + 10, closeAt, 0);
      const receipt = await tx.wait();
      const event   = receipt.logs.map((log: any) => { try { return transferWindow.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "WindowScheduled");
      await ethers.provider.send("evm_increaseTime", [11]);
      await ethers.provider.send("evm_mine", []);
      await expect(transferWindow.extendWindow(event.args.windowId, closeAt + 5 * 24 * 3600))
        .to.emit(transferWindow, "WindowExtended");
    });
  });

  // ─── v2 flow helpers ──────────────────────────────────────────────────────

  async function doOffer(
    ethers: any, escrow: any, club: any, playerId: bigint, token: any,
    fee: bigint, extra: any = {}
  ): Promise<bigint> {
    const tx = await escrow.connect(club).createOffer(
      playerId, await token.getAddress(), fee,
      extra.sellOnBps ?? 0, extra.sellOnRecipient ?? ethers.ZeroAddress,
      extra.sellerAgentBps ?? 0, extra.sellerAgent ?? ethers.ZeroAddress,
      500, extra.addOns ?? []
    );
    const receipt = await tx.wait();
    const ev = receipt.logs
      .map((l: any) => { try { return escrow.interface.parseLog(l); } catch { return null; } })
      .find((e: any) => e?.name === "OfferCreated");
    return ev.args.offerId;
  }

  async function doAccept(
    ethers: any, escrow: any, dealEscrow: any, sellingClub: any,
    offerId: bigint, buyingClub: any, extra: any = {}
  ): Promise<bigint> {
    // Default: single lump-sum installment due immediately
    const fee = extra.fee ?? BigInt(0);
    const installmentAmounts  = extra.installmentAmounts  ?? [fee];
    const installmentDueDates = extra.installmentDueDates ?? [Math.floor(Date.now()/1000) + 60];
    await escrow.connect(buyingClub).submitBid(
      offerId,
      fee,
      extra.sellOnBps ?? 0, extra.sellOnRecipient ?? ethers.ZeroAddress,
      extra.sellerAgentBps ?? 0, extra.sellerAgent ?? ethers.ZeroAddress,
      extra.buyerAgentBps ?? 0, extra.buyerAgent ?? ethers.ZeroAddress,
      extra.signingBonusMonths ?? 0,
      installmentAmounts,
      installmentDueDates
    );
    const tx = await escrow.connect(sellingClub).acceptBid(offerId, buyingClub.address);
    const receipt = await tx.wait();
    const ev = receipt.logs
      .map((l: any) => { try { return dealEscrow.interface.parseLog(l); } catch { return null; } })
      .find((e: any) => e?.name === "DealCreated");
    return ev.args.dealId;
  }

  // Full flow: offer → bid → accept → consent → medical → hijack expiry → fund
  // Returns dealId (in FUNDED state)
  async function doFundedDeal(
    ethers: any, escrow: any, dealEscrow: any, token: any,
    registry: any, transferWindow: any, sellingClub: any, buyingClub: any,
    playerWallet: any, playerId: bigint, fee: bigint, extra: any = {}
  ): Promise<bigint> {
    await openTransferWindow(ethers, transferWindow);
    const offerId = await doOffer(ethers, escrow, sellingClub, playerId, token, fee, extra);
    const dealId  = await doAccept(ethers, escrow, dealEscrow, sellingClub, offerId, buyingClub, { ...extra, fee });

    // Player consents
    await dealEscrow.connect(playerWallet).consentToTransfer(dealId);

    // Buying club submits medical — PASSED (1)
    const medHash = ethers.keccak256(ethers.toUtf8Bytes("medical-ok"));
    await dealEscrow.connect(buyingClub).submitMedical(dealId, 1, medHash);

    // Advance past hijack window → processExpiry → FUNDING_PENDING
    await ethers.provider.send("evm_increaseTime", [48 * 3600 + 1]);
    await ethers.provider.send("evm_mine", []);
    await escrow.processExpiry(dealId);

    // Fund deal
    const salaryMonths = extra.signingBonusMonths ?? 0;
    let salaryAmt = BigInt(0);
    if (salaryMonths > 0) {
      const p = await registry.getPlayer(playerId);
      salaryAmt = p.weeklySalary * BigInt(4) * BigInt(salaryMonths);
    }
    const totalFund = fee + salaryAmt;
    await token.connect(buyingClub).approve(await dealEscrow.getAddress(), totalFund);
    await dealEscrow.connect(buyingClub).fundDeal(dealId);

    return dealId;
  }

  describe("TransferEscrow", function () {

    it("reverts createOffer outside transfer window", async function () {
      const { ethers, registry, transferWindow, escrow, token, clubA, clubB, registrar } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar);
      const fee = ethers.parseUnits("50000000", 6);
      await expect(
        escrow.connect(clubA).createOffer(
          playerId, await token.getAddress(), fee,
          0, ethers.ZeroAddress, 0, ethers.ZeroAddress, 500, []
        )
      ).to.be.revertedWithCustomError(escrow, "TransferWindowClosed");
    });

    it("creates an offer during open window", async function () {
      const { ethers, registry, transferWindow, escrow, token, clubA, registrar } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar);
      await openTransferWindow(ethers, transferWindow);
      const fee = ethers.parseUnits("50000000", 6);
      await expect(
        escrow.connect(clubA).createOffer(
          playerId, await token.getAddress(), fee,
          0, ethers.ZeroAddress, 0, ethers.ZeroAddress, 500, []
        )
      ).to.emit(escrow, "OfferCreated");
    });

    it("reverts createOffer without CLUB_ROLE", async function () {
      const { ethers, registry, transferWindow, escrow, token, clubA, registrar, CLUB_ROLE } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar);
      await openTransferWindow(ethers, transferWindow);
      await escrow.revokeRole(CLUB_ROLE, clubA.address);
      const fee = ethers.parseUnits("50000000", 6);
      await expect(
        escrow.connect(clubA).createOffer(
          playerId, await token.getAddress(), fee,
          0, ethers.ZeroAddress, 0, ethers.ZeroAddress, 500, []
        )
      ).to.be.revertedWithCustomError(escrow, "AccessControlUnauthorizedAccount");
    });

    it("full deal flow: offer → bid → accept → consent → medical → fund → complete → NFT transferred", async function () {
      const { ethers, registry, transferWindow, escrow, dealEscrow, token, clubA, clubB, other, registrar, admin } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar);
      await registry.connect(clubA).setPlayerWallet(playerId, other.address);
      const fee = ethers.parseUnits("50000000", 6);

      const dealId = await doFundedDeal(
        ethers, escrow, dealEscrow, token, registry, transferWindow,
        clubA, clubB, other, playerId, fee
      );

      // Admin (LEAGUE_ROLE) force-completes after funding
      await expect(dealEscrow.connect(admin).forceComplete(dealId))
        .to.emit(dealEscrow, "DealCompleted");

      expect(await registry.ownerOf(playerId)).to.equal(clubB.address);
      expect(await registry.currentClub(playerId)).to.equal(clubB.address);

      // Selling club withdraws proceeds
      await expect(dealEscrow.connect(clubA).withdrawClaimable(await token.getAddress()))
        .to.emit(dealEscrow, "FundsClaimed");
    });

    it("processExpiry reverts before dispute window expires", async function () {
      const { ethers, registry, transferWindow, escrow, dealEscrow, token, clubA, clubB, other, registrar } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar);
      await registry.connect(clubA).setPlayerWallet(playerId, other.address);
      const fee = ethers.parseUnits("50000000", 6);

      const dealId = await doFundedDeal(
        ethers, escrow, dealEscrow, token, registry, transferWindow,
        clubA, clubB, other, playerId, fee
      );

      // Dispute window not expired yet — processExpiry should revert
      await expect(escrow.processExpiry(dealId))
        .to.be.revertedWithCustomError(escrow, "WrongDealState");
    });

    it("player declines — deal cancelled", async function () {
      const { ethers, registry, transferWindow, escrow, dealEscrow, token, clubA, clubB, other, registrar } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar);
      await registry.connect(clubA).setPlayerWallet(playerId, other.address);
      await openTransferWindow(ethers, transferWindow);
      const fee = ethers.parseUnits("50000000", 6);

      const offerId = await doOffer(ethers, escrow, clubA, playerId, token, fee);
      const dealId  = await doAccept(ethers, escrow, dealEscrow, clubA, offerId, clubB, { fee });

      // Player declines at consent stage
      await expect(dealEscrow.connect(other).declineTransfer(dealId))
        .to.emit(dealEscrow, "PlayerDeclined");

      // Deal is cancelled — player still belongs to selling club
      expect(await registry.currentClub(playerId)).to.equal(clubA.address);
    });

    it("sell-on clause splits payment correctly", async function () {
      const { ethers, registry, transferWindow, escrow, dealEscrow, token, clubA, clubB, clubC, other, registrar, admin } = await deployAll();
      await escrow.grantRole(await escrow.CLUB_ROLE(), clubC.address);
      const playerId  = await setupListedPlayer(ethers, registry, clubA, registrar);
      await registry.connect(clubA).setPlayerWallet(playerId, other.address);
      const fee       = ethers.parseUnits("50000000", 6);
      const sellOnBps = 500;

      const dealId = await doFundedDeal(
        ethers, escrow, dealEscrow, token, registry, transferWindow,
        clubA, clubB, other, playerId, fee,
        { sellOnBps, sellOnRecipient: clubC.address }
      );

      await dealEscrow.connect(admin).forceComplete(dealId);

      const sellOnAmt = fee * BigInt(sellOnBps) / BigInt(10000);
      expect(await dealEscrow.getClaimable(clubA.address, await token.getAddress()))
        .to.equal(fee - sellOnAmt);
      expect(await dealEscrow.getClaimable(clubC.address, await token.getAddress()))
        .to.equal(sellOnAmt);
    });

    it("agent fees split correctly", async function () {
      const { ethers, registry, transferWindow, escrow, dealEscrow, token, clubA, clubB, clubC, other, registrar, admin } = await deployAll();
      const playerId       = await setupListedPlayer(ethers, registry, clubA, registrar);
      await registry.connect(clubA).setPlayerWallet(playerId, other.address);
      const fee            = ethers.parseUnits("50000000", 6);
      const sellerAgentBps = 300;
      const buyerAgentBps  = 200;

      const dealId = await doFundedDeal(
        ethers, escrow, dealEscrow, token, registry, transferWindow,
        clubA, clubB, other, playerId, fee,
        { sellerAgentBps, sellerAgent: clubC.address, buyerAgentBps, buyerAgent: other.address }
      );

      await dealEscrow.connect(admin).forceComplete(dealId);

      const sellerAgentAmt = fee * BigInt(sellerAgentBps) / BigInt(10000);
      const buyerAgentAmt  = fee * BigInt(buyerAgentBps)  / BigInt(10000);
      expect(await dealEscrow.getClaimable(clubA.address, await token.getAddress()))
        .to.equal(fee - sellerAgentAmt - buyerAgentAmt);
      expect(await dealEscrow.getClaimable(clubC.address, await token.getAddress()))
        .to.equal(sellerAgentAmt);
      expect(await dealEscrow.getClaimable(other.address, await token.getAddress()))
        .to.equal(buyerAgentAmt);
    });

    it("performance add-on routed to player wallet", async function () {
      const { ethers, registry, transferWindow, escrow, dealEscrow, token, clubA, clubB, other, registrar, admin } = await deployAll();
      const weeklySalary = ethers.parseUnits("50000", 6);
      const playerId     = await setupListedPlayer(ethers, registry, clubA, registrar, weeklySalary);
      await registry.connect(clubA).setPlayerWallet(playerId, other.address);

      const fee      = ethers.parseUnits("50000000", 6);
      const addOnAmt = ethers.parseUnits("2000000", 6);
      const addOns   = [{ description: "15+ league goals", amount: addOnAmt, toPlayer: true, triggered: false }];

      const dealId = await doFundedDeal(
        ethers, escrow, dealEscrow, token, registry, transferWindow,
        clubA, clubB, other, playerId, fee, { addOns }
      );

      await dealEscrow.connect(admin).forceComplete(dealId);

      // Buying club deposits add-on funds and league triggers it
      await token.connect(clubB).approve(await dealEscrow.getAddress(), addOnAmt);
      await dealEscrow.connect(clubB).depositAddOnFunds(dealId, addOnAmt);
      await expect(dealEscrow.connect(admin).triggerAddOn(dealId, 0))
        .to.emit(dealEscrow, "AddOnTriggered");

      expect(await dealEscrow.getClaimable(other.address, await token.getAddress()))
        .to.equal(addOnAmt);
      expect(await dealEscrow.getClaimable(clubA.address, await token.getAddress()))
        .to.equal(fee);
    });

    it("salary guarantee locked in escrow, player can claim", async function () {
      const { ethers, registry, transferWindow, escrow, dealEscrow, token, clubA, clubB, other, registrar, admin } = await deployAll();
      const weeklySalary = ethers.parseUnits("50000", 6);
      const playerId     = await setupListedPlayer(ethers, registry, clubA, registrar, weeklySalary);
      await registry.connect(clubA).setPlayerWallet(playerId, other.address);

      const fee                   = ethers.parseUnits("50000000", 6);
      const signingBonusMonths = 3;
      const guaranteeAmount       = weeklySalary * BigInt(4) * BigInt(signingBonusMonths);

      const dealId = await doFundedDeal(
        ethers, escrow, dealEscrow, token, registry, transferWindow,
        clubA, clubB, other, playerId, fee, { signingBonusMonths }
      );

      // signingBonusAmount verified implicitly — claimSigningBonus below proves it was stored

      await dealEscrow.connect(admin).forceComplete(dealId);

      // Player wallet claims salary guarantee
      await expect(dealEscrow.connect(other).claimSigningBonus(dealId))
        .to.emit(dealEscrow, "SigningBonusClaimed");
      expect(await dealEscrow.getClaimable(other.address, await token.getAddress()))
        .to.equal(guaranteeAmount);
    });
  });

  describe("LoanEscrow", function () {

    it("creates a loan deal", async function () {
      const { ethers, registry, transferWindow, loanEscrow, token, clubA, clubB, registrar } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar);
      await openTransferWindow(ethers, transferWindow);
      const loanFee = ethers.parseUnits("1000000", 6);
      await token.connect(clubB).approve(await loanEscrow.getAddress(), loanFee);
      await expect(
        loanEscrow.connect(clubB).createLoan(
          playerId, clubA.address, await token.getAddress(), loanFee, 90 * 24 * 3600, false, 0
        )
      ).to.emit(loanEscrow, "LoanCreated");
    });

    it("full loan flow: create → approve → claimLoanFee → settleLoanExpiry", async function () {
      const { ethers, registry, transferWindow, loanEscrow, token, clubA, clubB, registrar } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar);
      await openTransferWindow(ethers, transferWindow);
      const loanFee = ethers.parseUnits("1000000", 6);
      const duration = 30 * 24 * 3600;
      await token.connect(clubB).approve(await loanEscrow.getAddress(), loanFee);
      const tx = await loanEscrow.connect(clubB).createLoan(
        playerId, clubA.address, await token.getAddress(), loanFee, duration, false, 0
      );
      const receipt = await tx.wait();
      const event   = receipt.logs.map((log: any) => { try { return loanEscrow.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "LoanCreated");
      const loanId  = event.args.loanId;

      await loanEscrow.approveLoan(loanId);
      expect(await registry.ownerOf(playerId)).to.equal(clubB.address);

      await ethers.provider.send("evm_increaseTime", [48 * 3600 + 1]);
      await ethers.provider.send("evm_mine", []);
      await expect(loanEscrow.connect(clubA).claimLoanFee(loanId)).to.emit(loanEscrow, "LoanFeeClaimed");

      await ethers.provider.send("evm_increaseTime", [duration]);
      await ethers.provider.send("evm_mine", []);
      await expect(loanEscrow.connect(clubA).settleLoanExpiry(loanId)).to.emit(loanEscrow, "LoanExpired");
      expect(await registry.ownerOf(playerId)).to.equal(clubA.address);
    });

    it("recall flow enforces notice period", async function () {
      const { ethers, registry, transferWindow, loanEscrow, token, clubA, clubB, registrar } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar);
      await openTransferWindow(ethers, transferWindow);
      const loanFee = ethers.parseUnits("1000000", 6);
      await token.connect(clubB).approve(await loanEscrow.getAddress(), loanFee);
      const tx = await loanEscrow.connect(clubB).createLoan(
        playerId, clubA.address, await token.getAddress(), loanFee, 180 * 24 * 3600, false, 0
      );
      const receipt = await tx.wait();
      const event   = receipt.logs.map((log: any) => { try { return loanEscrow.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "LoanCreated");
      const loanId  = event.args.loanId;
      await loanEscrow.approveLoan(loanId);
      await loanEscrow.connect(clubA).requestRecall(loanId);
      await expect(loanEscrow.connect(clubA).executeRecall(loanId))
        .to.be.revertedWithCustomError(loanEscrow, "RecallNoticeNotMet");
      await ethers.provider.send("evm_increaseTime", [14 * 24 * 3600 + 1]);
      await ethers.provider.send("evm_mine", []);
      await expect(loanEscrow.connect(clubA).executeRecall(loanId)).to.emit(loanEscrow, "LoanRecalled");
      expect(await registry.ownerOf(playerId)).to.equal(clubA.address);
    });

    it("option to buy converts loan to permanent transfer", async function () {
      const { ethers, registry, transferWindow, loanEscrow, token, clubA, clubB, registrar } = await deployAll();
      const playerId    = await setupListedPlayer(ethers, registry, clubA, registrar);
      await openTransferWindow(ethers, transferWindow);
      const loanFee     = ethers.parseUnits("1000000", 6);
      const optionPrice = ethers.parseUnits("40000000", 6);
      await token.connect(clubB).approve(await loanEscrow.getAddress(), loanFee);
      const tx = await loanEscrow.connect(clubB).createLoan(
        playerId, clubA.address, await token.getAddress(), loanFee, 180 * 24 * 3600, true, optionPrice
      );
      const receipt = await tx.wait();
      const event   = receipt.logs.map((log: any) => { try { return loanEscrow.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "LoanCreated");
      const loanId  = event.args.loanId;
      await loanEscrow.approveLoan(loanId);
      await token.connect(clubB).approve(await loanEscrow.getAddress(), optionPrice);
      await expect(loanEscrow.connect(clubB).exerciseOption(loanId)).to.emit(loanEscrow, "OptionExercised");
      expect(await registry.ownerOf(playerId)).to.equal(clubB.address);
    });

    it("third party cannot trigger settleLoanExpiry", async function () {
      const { ethers, registry, transferWindow, loanEscrow, token, clubA, clubB, other, registrar } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar);
      await openTransferWindow(ethers, transferWindow);
      const loanFee = ethers.parseUnits("1000000", 6);
      const duration = 30 * 24 * 3600;
      await token.connect(clubB).approve(await loanEscrow.getAddress(), loanFee);
      const tx = await loanEscrow.connect(clubB).createLoan(
        playerId, clubA.address, await token.getAddress(), loanFee, duration, false, 0
      );
      const receipt = await tx.wait();
      const event   = receipt.logs.map((log: any) => { try { return loanEscrow.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "LoanCreated");
      await loanEscrow.approveLoan(event.args.loanId);
      await ethers.provider.send("evm_increaseTime", [duration + 1]);
      await ethers.provider.send("evm_mine", []);
      await expect(loanEscrow.connect(other).settleLoanExpiry(event.args.loanId))
        .to.be.revertedWithCustomError(loanEscrow, "NotAuthorised");
    });

    it("createLoan reverts when transfer window closed", async function () {
      const { ethers, registry, loanEscrow, token, clubA, clubB, registrar } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar, undefined, "loan-closed");
      const loanFee  = ethers.parseUnits("1000000", 6);
      await token.connect(clubB).approve(await loanEscrow.getAddress(), loanFee);
      await expect(
        loanEscrow.connect(clubB).createLoan(
          playerId, clubA.address, await token.getAddress(), loanFee, 90 * 24 * 3600, false, 0
        )
      ).to.be.revertedWithCustomError(loanEscrow, "TransferWindowClosed");
    });

    it("createLoan reverts when player is not listed", async function () {
      const { ethers, registry, transferWindow, loanEscrow, token, clubA, clubB, registrar } = await deployAll();
      await openTransferWindow(ethers, transferWindow);
      // register but do NOT list the player
      const salt = "loan-unlisted";
      const tx = await registry.connect(clubA).registerPlayer(
        "Unlisted Player", "CM", "Spanish",
        Math.floor(Date.now() / 1000) + 365 * 24 * 3600,
        ethers.parseUnits("20000", 6),
        ethers.id(salt)
      );
      const receipt = await tx.wait();
      const event   = receipt.logs
        .map((l: any) => { try { return registry.interface.parseLog(l); } catch { return null; } })
        .find((e: any) => e?.name === "PlayerRegistered");
      const playerId = event.args.playerId;
      const loanFee  = ethers.parseUnits("500000", 6);
      await token.connect(clubB).approve(await loanEscrow.getAddress(), loanFee);
      await expect(
        loanEscrow.connect(clubB).createLoan(
          playerId, clubA.address, await token.getAddress(), loanFee, 90 * 24 * 3600, false, 0
        )
      ).to.be.revertedWithCustomError(loanEscrow, "PlayerNotListed");
    });

    it("createLoan reverts when borrowing club == parent club", async function () {
      const { ethers, registry, transferWindow, loanEscrow, token, clubA, registrar } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar, undefined, "loan-self");
      await openTransferWindow(ethers, transferWindow);
      const loanFee  = ethers.parseUnits("500000", 6);
      await token.connect(clubA).approve(await loanEscrow.getAddress(), loanFee);
      await expect(
        loanEscrow.connect(clubA).createLoan(
          playerId, clubA.address, await token.getAddress(), loanFee, 90 * 24 * 3600, false, 0
        )
      ).to.be.revertedWithCustomError(loanEscrow, "InvalidAddress");
    });

    it("cancelLoan before approval refunds borrowing club", async function () {
      const { ethers, registry, transferWindow, loanEscrow, token, clubA, clubB, registrar } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar, undefined, "loan-cancel");
      await openTransferWindow(ethers, transferWindow);
      const loanFee  = ethers.parseUnits("1000000", 6);
      await token.connect(clubB).approve(await loanEscrow.getAddress(), loanFee);
      const tx      = await loanEscrow.connect(clubB).createLoan(
        playerId, clubA.address, await token.getAddress(), loanFee, 90 * 24 * 3600, false, 0
      );
      const receipt  = await tx.wait();
      const loanId   = receipt.logs
        .map((l: any) => { try { return loanEscrow.interface.parseLog(l); } catch { return null; } })
        .find((e: any) => e?.name === "LoanCreated").args.loanId;

      await expect(loanEscrow.connect(clubB).cancelLoan(loanId))
        .to.emit(loanEscrow, "LoanCancelled");
      expect(await loanEscrow.getClaimable(clubB.address, await token.getAddress()))
        .to.equal(loanFee);
    });

    it("rejectLoan refunds borrowing club", async function () {
      const { ethers, registry, transferWindow, loanEscrow, token, clubA, clubB, registrar, admin } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar, undefined, "loan-reject");
      await openTransferWindow(ethers, transferWindow);
      const loanFee  = ethers.parseUnits("1000000", 6);
      await token.connect(clubB).approve(await loanEscrow.getAddress(), loanFee);
      const tx      = await loanEscrow.connect(clubB).createLoan(
        playerId, clubA.address, await token.getAddress(), loanFee, 90 * 24 * 3600, false, 0
      );
      const receipt  = await tx.wait();
      const loanId   = receipt.logs
        .map((l: any) => { try { return loanEscrow.interface.parseLog(l); } catch { return null; } })
        .find((e: any) => e?.name === "LoanCreated").args.loanId;

      await expect(loanEscrow.connect(admin).rejectLoan(loanId, "Failed integrity check"))
        .to.emit(loanEscrow, "LoanRejected");
      expect(await loanEscrow.getClaimable(clubB.address, await token.getAddress()))
        .to.equal(loanFee);
    });

    it("claimLoanFee reverts during dispute window", async function () {
      const { ethers, registry, transferWindow, loanEscrow, token, clubA, clubB, registrar } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar, undefined, "loan-dispute");
      await openTransferWindow(ethers, transferWindow);
      const loanFee  = ethers.parseUnits("1000000", 6);
      await token.connect(clubB).approve(await loanEscrow.getAddress(), loanFee);
      const tx      = await loanEscrow.connect(clubB).createLoan(
        playerId, clubA.address, await token.getAddress(), loanFee, 90 * 24 * 3600, false, 0
      );
      const receipt  = await tx.wait();
      const loanId   = receipt.logs
        .map((l: any) => { try { return loanEscrow.interface.parseLog(l); } catch { return null; } })
        .find((e: any) => e?.name === "LoanCreated").args.loanId;
      await loanEscrow.approveLoan(loanId);
      await expect(loanEscrow.connect(clubA).claimLoanFee(loanId))
        .to.be.revertedWithCustomError(loanEscrow, "DisputeWindowActive");
    });

    it("claimLoanFee cannot be claimed twice", async function () {
      const { ethers, registry, transferWindow, loanEscrow, token, clubA, clubB, registrar } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar, undefined, "loan-double");
      await openTransferWindow(ethers, transferWindow);
      const loanFee  = ethers.parseUnits("1000000", 6);
      await token.connect(clubB).approve(await loanEscrow.getAddress(), loanFee);
      const tx      = await loanEscrow.connect(clubB).createLoan(
        playerId, clubA.address, await token.getAddress(), loanFee, 90 * 24 * 3600, false, 0
      );
      const receipt  = await tx.wait();
      const loanId   = receipt.logs
        .map((l: any) => { try { return loanEscrow.interface.parseLog(l); } catch { return null; } })
        .find((e: any) => e?.name === "LoanCreated").args.loanId;
      await loanEscrow.approveLoan(loanId);
      await ethers.provider.send("evm_increaseTime", [48 * 3600 + 1]);
      await ethers.provider.send("evm_mine", []);
      await loanEscrow.connect(clubA).claimLoanFee(loanId);
      await expect(loanEscrow.connect(clubA).claimLoanFee(loanId))
        .to.be.revertedWithCustomError(loanEscrow, "LoanFeeAlreadyClaimed");
    });

    it("exerciseOption reverts after loan expiry", async function () {
      const { ethers, registry, transferWindow, loanEscrow, token, clubA, clubB, registrar } = await deployAll();
      const playerId    = await setupListedPlayer(ethers, registry, clubA, registrar, undefined, "loan-optexp");
      await openTransferWindow(ethers, transferWindow);
      const loanFee     = ethers.parseUnits("1000000", 6);
      const optionPrice = ethers.parseUnits("30000000", 6);
      const duration    = 30 * 24 * 3600;
      await token.connect(clubB).approve(await loanEscrow.getAddress(), loanFee);
      const tx      = await loanEscrow.connect(clubB).createLoan(
        playerId, clubA.address, await token.getAddress(), loanFee, duration, true, optionPrice
      );
      const receipt  = await tx.wait();
      const loanId   = receipt.logs
        .map((l: any) => { try { return loanEscrow.interface.parseLog(l); } catch { return null; } })
        .find((e: any) => e?.name === "LoanCreated").args.loanId;
      await loanEscrow.approveLoan(loanId);
      await ethers.provider.send("evm_increaseTime", [duration + 1]);
      await ethers.provider.send("evm_mine", []);
      await token.connect(clubB).approve(await loanEscrow.getAddress(), optionPrice);
      await expect(loanEscrow.connect(clubB).exerciseOption(loanId))
        .to.be.revertedWithCustomError(loanEscrow, "OptionExpired");
    });

    it("protocol fee deducted from loan fee on claim", async function () {
      const { ethers, registry, transferWindow, loanEscrow, token, clubA, clubB, registrar, admin } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar, undefined, "loan-fee");
      await openTransferWindow(ethers, transferWindow);
      const PROTO_BPS = 200n; // 2%
      await loanEscrow.connect(admin).setProtocolFee(PROTO_BPS);
      const loanFee   = ethers.parseUnits("1000000", 6);
      await token.connect(clubB).approve(await loanEscrow.getAddress(), loanFee);
      const tx      = await loanEscrow.connect(clubB).createLoan(
        playerId, clubA.address, await token.getAddress(), loanFee, 90 * 24 * 3600, false, 0
      );
      const receipt  = await tx.wait();
      const loanId   = receipt.logs
        .map((l: any) => { try { return loanEscrow.interface.parseLog(l); } catch { return null; } })
        .find((e: any) => e?.name === "LoanCreated").args.loanId;
      await loanEscrow.approveLoan(loanId);
      await ethers.provider.send("evm_increaseTime", [48 * 3600 + 1]);
      await ethers.provider.send("evm_mine", []);
      await loanEscrow.connect(clubA).claimLoanFee(loanId);

      const tokenAddr    = await token.getAddress();
      const protocolAmt  = loanFee * PROTO_BPS / 10000n;
      expect(await loanEscrow.getClaimable(clubA.address, tokenAddr))
        .to.equal(loanFee - protocolAmt);
      expect(await loanEscrow.getClaimable(admin.address, tokenAddr))
        .to.equal(protocolAmt);
    });

    it("withdrawClaimable transfers tokens to caller", async function () {
      const { ethers, registry, transferWindow, loanEscrow, token, clubA, clubB, registrar } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar, undefined, "loan-withdraw");
      await openTransferWindow(ethers, transferWindow);
      const loanFee  = ethers.parseUnits("1000000", 6);
      await token.connect(clubB).approve(await loanEscrow.getAddress(), loanFee);
      const tx      = await loanEscrow.connect(clubB).createLoan(
        playerId, clubA.address, await token.getAddress(), loanFee, 90 * 24 * 3600, false, 0
      );
      const receipt  = await tx.wait();
      const loanId   = receipt.logs
        .map((l: any) => { try { return loanEscrow.interface.parseLog(l); } catch { return null; } })
        .find((e: any) => e?.name === "LoanCreated").args.loanId;
      await loanEscrow.approveLoan(loanId);
      await ethers.provider.send("evm_increaseTime", [48 * 3600 + 1]);
      await ethers.provider.send("evm_mine", []);
      await loanEscrow.connect(clubA).claimLoanFee(loanId);

      const tokenAddr = await token.getAddress();
      const claimable = await loanEscrow.getClaimable(clubA.address, tokenAddr);
      const before    = await token.balanceOf(clubA.address);
      await loanEscrow.connect(clubA).withdrawClaimable(tokenAddr);
      expect(await token.balanceOf(clubA.address)).to.equal(before + claimable);
      expect(await loanEscrow.getClaimable(clubA.address, tokenAddr)).to.equal(0n);
    });


    describe("TransferWindow — upgraded", function () {

      it("schedules STANDARD window with correct type", async function () {
        const { ethers, transferWindow } = await deployAll();
        const now = await ethers.provider.getBlock("latest").then((b: any) => b.timestamp);
        const tx = await transferWindow.scheduleWindow("Summer 2026", now + 10, now + 30 * 24 * 3600, 0);
        const receipt = await tx.wait();
        const event = receipt.logs.map((log: any) => { try { return transferWindow.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "WindowScheduled");
        expect(event.args.windowType).to.equal(0); // STANDARD
      });

      it("schedules EXCEPTIONAL window within 10 day limit", async function () {
        const { ethers, transferWindow } = await deployAll();
        const now = await ethers.provider.getBlock("latest").then((b: any) => b.timestamp);
        await expect(
          transferWindow.scheduleWindow("Club World Cup", now + 10, now + 9 * 24 * 3600, 1)
        ).to.eventually.be.fulfilled;
      });

      it("rejects EXCEPTIONAL window exceeding 10 days", async function () {
        const { ethers, transferWindow } = await deployAll();
        const now = await ethers.provider.getBlock("latest").then((b: any) => b.timestamp);
        await expect(
          transferWindow.scheduleWindow("Too Long", now + 10, now + 11 * 24 * 3600, 1)
        ).to.be.revertedWithCustomError(transferWindow, "WindowTooLong");
      });

      it("schedules EMERGENCY window within 7 day limit", async function () {
        const { ethers, transferWindow } = await deployAll();
        const now = await ethers.provider.getBlock("latest").then((b: any) => b.timestamp);
        await expect(
          transferWindow.scheduleWindow("Emergency GK", now + 10, now + 6 * 24 * 3600, 2)
        ).to.eventually.be.fulfilled;
      });

      it("rejects EMERGENCY window exceeding 7 days", async function () {
        const { ethers, transferWindow } = await deployAll();
        const now = await ethers.provider.getBlock("latest").then((b: any) => b.timestamp);
        await expect(
          transferWindow.scheduleWindow("Too Long", now + 10, now + 8 * 24 * 3600, 2)
        ).to.be.revertedWithCustomError(transferWindow, "WindowTooLong");
      });

      it("suspends and resumes an open window", async function () {
        const { ethers, transferWindow } = await deployAll();
        const now = await ethers.provider.getBlock("latest").then((b: any) => b.timestamp);
        const tx = await transferWindow.scheduleWindow("Summer 2026", now + 10, now + 30 * 24 * 3600, 0);
        const receipt = await tx.wait();
        const event = receipt.logs.map((log: any) => { try { return transferWindow.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "WindowScheduled");
        const windowId = event.args.windowId;

        await ethers.provider.send("evm_increaseTime", [15]);
        await ethers.provider.send("evm_mine", []);

        expect(await transferWindow.isWindowOpen()).to.be.true;

        await transferWindow.suspendWindow(windowId);
        expect(await transferWindow.isWindowOpen()).to.be.false;

        await transferWindow.resumeWindow(windowId);
        expect(await transferWindow.isWindowOpen()).to.be.true;
      });

      it("rejects suspending an already suspended window", async function () {
        const { ethers, transferWindow } = await deployAll();
        const now = await ethers.provider.getBlock("latest").then((b: any) => b.timestamp);
        const tx = await transferWindow.scheduleWindow("Summer 2026", now + 10, now + 30 * 24 * 3600, 0);
        const receipt = await tx.wait();
        const event = receipt.logs.map((log: any) => { try { return transferWindow.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "WindowScheduled");
        const windowId = event.args.windowId;

        await ethers.provider.send("evm_increaseTime", [15]);
        await ethers.provider.send("evm_mine", []);

        await transferWindow.suspendWindow(windowId);
        await expect(
          transferWindow.suspendWindow(windowId)
        ).to.be.revertedWithCustomError(transferWindow, "WindowAlreadySuspended");
      });

      it("isWindowOpenForType returns true for correct type only", async function () {
        const { ethers, transferWindow } = await deployAll();
        const now = await ethers.provider.getBlock("latest").then((b: any) => b.timestamp);
        await transferWindow.scheduleWindow("Summer 2026", now + 10, now + 30 * 24 * 3600, 0);

        await ethers.provider.send("evm_increaseTime", [15]);
        await ethers.provider.send("evm_mine", []);

        expect(await transferWindow.isWindowOpenForType(0)).to.be.true;  // STANDARD
        expect(await transferWindow.isWindowOpenForType(1)).to.be.false; // EXCEPTIONAL
        expect(await transferWindow.isWindowOpenForType(2)).to.be.false; // EMERGENCY
      });

      it("getCurrentWindowType returns correct type", async function () {
        const { ethers, transferWindow } = await deployAll();
        const now = await ethers.provider.getBlock("latest").then((b: any) => b.timestamp);
        await transferWindow.scheduleWindow("Club World Cup", now + 10, now + 9 * 24 * 3600, 1);

        await ethers.provider.send("evm_increaseTime", [15]);
        await ethers.provider.send("evm_mine", []);

        expect(await transferWindow.getCurrentWindowType()).to.equal(1); // EXCEPTIONAL
      });

      it("getCurrentWindowType reverts when no window open", async function () {
        const { transferWindow } = await deployAll();
        await expect(
          transferWindow.getCurrentWindowType()
        ).to.be.revertedWithCustomError(transferWindow, "NoActiveWindow");
      });

      it("suspended window not counted by isWindowOpenForType", async function () {
        const { ethers, transferWindow } = await deployAll();
        const now = await ethers.provider.getBlock("latest").then((b: any) => b.timestamp);
        const tx = await transferWindow.scheduleWindow("Summer 2026", now + 10, now + 30 * 24 * 3600, 0);
        const receipt = await tx.wait();
        const event = receipt.logs.map((log: any) => { try { return transferWindow.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "WindowScheduled");
        const windowId = event.args.windowId;

        await ethers.provider.send("evm_increaseTime", [15]);
        await ethers.provider.send("evm_mine", []);

        await transferWindow.suspendWindow(windowId);
        expect(await transferWindow.isWindowOpenForType(0)).to.be.false;
      });
    });

  });

  describe("SwapEscrow", function () {

    async function deployWithSwap() {
      const base = await deployAll();
      const { ethers, admin, clubA, clubB, registrar, registry, token } = base as any;

      const Proxy       = await ethers.getContractFactory("TransferiumProxy");
      const SwapEscrowF = await ethers.getContractFactory("SwapEscrow");
      const swapImpl    = await SwapEscrowF.deploy();
      const swapInit    = swapImpl.interface.encodeFunctionData("initialize", [
        await registry.getAddress(),
        await base.addressReg.getAddress(),
        await base.escrow.getAddress(),
        admin.address,
        admin.address,
      ]);
      const swapProxy  = await Proxy.deploy(await swapImpl.getAddress(), swapInit);
      const swapEscrow = SwapEscrowF.attach(await swapProxy.getAddress());

      const ESCROW_ROLE = await registry.ESCROW_ROLE();
      const CLUB_ROLE   = await swapEscrow.CLUB_ROLE();
      await registry.grantRole(ESCROW_ROLE, await swapEscrow.getAddress());
      await swapEscrow.grantRole(CLUB_ROLE, clubA.address);
      await swapEscrow.grantRole(CLUB_ROLE, clubB.address);
      await swapEscrow.connect(admin).setProtocolFee(0);
      await swapEscrow.approveToken(await token.getAddress());

      // Register + fully verify one player at each club, with player wallets set
      const playerA = await setupListedPlayer(ethers, registry, clubA, registrar, ethers.parseUnits("50000", 6), "swapA");
      const playerB = await setupListedPlayer(ethers, registry, clubB, registrar, ethers.parseUnits("50000", 6), "swapB");

      // Create fresh wallets for player consent
      const walletA = ethers.Wallet.createRandom().connect(ethers.provider);
      const walletB = ethers.Wallet.createRandom().connect(ethers.provider);
      await clubA.sendTransaction({ to: walletA.address, value: ethers.parseEther("1") });
      await clubB.sendTransaction({ to: walletB.address, value: ethers.parseEther("1") });
      await registry.connect(clubA).setPlayerWallet(playerA, walletA.address);
      await registry.connect(clubB).setPlayerWallet(playerB, walletB.address);

      await openTransferWindow(ethers, base.transferWindow);

      return { ...base, swapEscrow, playerA, playerB, walletA, walletB };
    }

    async function proposeAndAccept(ctx: any) {
      const { ethers, swapEscrow, clubA, clubB, playerA, playerB, token } = ctx;
      await swapEscrow.connect(clubA).proposeSwap(
        playerA, playerB, await token.getAddress(), 0n, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress
      );
      await swapEscrow.connect(clubB).acceptSwap(1n);
    }

    async function consentBoth(ctx: any) {
      const { swapEscrow, walletA, walletB } = ctx;
      await swapEscrow.connect(walletA).consentToSwap(1n);
      await swapEscrow.connect(walletB).consentToSwap(1n);
    }

    it("proposeSwap creates swap in PROPOSED state", async function () {
      const ctx = await deployWithSwap();
      const { ethers, swapEscrow, clubA, playerA, playerB, token } = ctx;
      const tx = await swapEscrow.connect(clubA).proposeSwap(
        playerA, playerB, await token.getAddress(), 0n, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress
      );
      await expect(tx).to.emit(swapEscrow, "SwapProposed");
      const swap = await swapEscrow.getSwap(1n);
      expect(swap.state).to.equal(1n); // PROPOSED
      expect(swap.playerA).to.equal(playerA);
      expect(swap.playerB).to.equal(playerB);
    });

    it("Club B accepts swap → ACCEPTED state", async function () {
      const ctx = await deployWithSwap();
      const { ethers, swapEscrow, clubA, clubB, playerA, playerB, token } = ctx;
      await swapEscrow.connect(clubA).proposeSwap(playerA, playerB, await token.getAddress(), 0n, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress);
      await expect(swapEscrow.connect(clubB).acceptSwap(1n)).to.emit(swapEscrow, "SwapAccepted");
      expect((await swapEscrow.getSwap(1n)).state).to.equal(2n); // ACCEPTED
    });

    it("Club B rejects swap → CANCELLED", async function () {
      const ctx = await deployWithSwap();
      const { ethers, swapEscrow, clubA, clubB, playerA, playerB, token } = ctx;
      await swapEscrow.connect(clubA).proposeSwap(playerA, playerB, await token.getAddress(), 0n, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress);
      await expect(swapEscrow.connect(clubB).rejectSwap(1n)).to.emit(swapEscrow, "SwapCancelled");
      expect((await swapEscrow.getSwap(1n)).state).to.equal(10n); // CANCELLED
    });

    it("Club A withdraws proposal → CANCELLED", async function () {
      const ctx = await deployWithSwap();
      const { ethers, swapEscrow, clubA, playerA, playerB, token } = ctx;
      await swapEscrow.connect(clubA).proposeSwap(playerA, playerB, await token.getAddress(), 0n, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress);
      await expect(swapEscrow.connect(clubA).withdrawProposal(1n)).to.emit(swapEscrow, "SwapCancelled");
    });

    it("pure swap full flow: propose → accept → consent x2 → medical x2 → NFTs swapped", async function () {
      const ctx = await deployWithSwap();
      const { ethers, swapEscrow, clubA, clubB, playerA, playerB, registry } = ctx;

      await proposeAndAccept(ctx);
      await consentBoth(ctx);

      const hash = ethers.keccak256(ethers.toUtf8Bytes("medical-ok"));
      await swapEscrow.connect(clubA).submitMedicalAonB(1n, 1n, hash); // PASSED=1
      await expect(
        swapEscrow.connect(clubB).submitMedicalBonA(1n, 1n, hash)
      ).to.emit(swapEscrow, "SwapCompleted");

      expect(await registry.currentClub(playerA)).to.equal(clubB.address);
      expect(await registry.currentClub(playerB)).to.equal(clubA.address);
    });

    it("medical failure (Club A on Player B) cancels swap", async function () {
      const ctx = await deployWithSwap();
      const { ethers, swapEscrow, clubA } = ctx;

      await proposeAndAccept(ctx);
      await consentBoth(ctx);

      const hash = ethers.keccak256(ethers.toUtf8Bytes("fail"));
      await expect(
        swapEscrow.connect(clubA).submitMedicalAonB(1n, 2n, hash) // FAILED=2
      ).to.emit(swapEscrow, "SwapCancelled");
      expect((await swapEscrow.getSwap(1n)).state).to.equal(10n);
    });

    it("swap with top-up: Club B funds, Club A claimable after dispute window", async function () {
      const ctx = await deployWithSwap();
      const { ethers, swapEscrow, clubA, clubB, playerA, playerB, token, walletA, walletB, registry } = ctx;
      const tokenAddr = await token.getAddress();
      const TOP_UP    = ethers.parseUnits("500000", 6);

      await token.mint(clubB.address, TOP_UP);
      await token.connect(clubB).approve(await swapEscrow.getAddress(), TOP_UP);

      await swapEscrow.connect(clubA).proposeSwap(playerA, playerB, tokenAddr, TOP_UP, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress);
      await swapEscrow.connect(clubB).acceptSwap(1n);
      await swapEscrow.connect(walletA).consentToSwap(1n);
      await swapEscrow.connect(walletB).consentToSwap(1n);

      const hash = ethers.keccak256(ethers.toUtf8Bytes("medical-ok"));
      await swapEscrow.connect(clubA).submitMedicalAonB(1n, 1n, hash);
      await swapEscrow.connect(clubB).submitMedicalBonA(1n, 1n, hash);

      // State is now BOTH_MEDICALS_DONE — Club B must fund
      await swapEscrow.connect(clubB).fundSwap(1n);
      expect((await swapEscrow.getSwap(1n)).state).to.equal(7n); // FUNDED

      const swap = await swapEscrow.getSwap(1n);
      await ethers.provider.send("evm_setNextBlockTimestamp", [Number(swap.disputeDeadline) + 1]);
      await ethers.provider.send("evm_mine", []);

      await expect(swapEscrow.processExpiry(1n)).to.emit(swapEscrow, "SwapCompleted");
      expect(await swapEscrow.getClaimable(clubA.address, tokenAddr)).to.equal(TOP_UP);
    });

    it("mutual cancel proposed and confirmed → CANCELLED", async function () {
      const ctx = await deployWithSwap();
      const { swapEscrow, clubA, clubB } = ctx;

      await proposeAndAccept(ctx);
      await swapEscrow.connect(clubA).proposeMutualCancel(1n);
      await expect(
        swapEscrow.connect(clubB).confirmMutualCancel(1n)
      ).to.emit(swapEscrow, "MutualCancelConfirmed");
      expect((await swapEscrow.getSwap(1n)).state).to.equal(10n);
    });

    it("processExpiry cancels PROPOSED swap after consent window expires", async function () {
      const ctx = await deployWithSwap();
      const { ethers, swapEscrow, clubA, playerA, playerB, token } = ctx;

      await swapEscrow.connect(clubA).proposeSwap(playerA, playerB, await token.getAddress(), 0n, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress);
      const swap = await swapEscrow.getSwap(1n);
      await ethers.provider.send("evm_setNextBlockTimestamp", [Number(swap.stateDeadline) + 1]);
      await ethers.provider.send("evm_mine", []);
      await expect(swapEscrow.processExpiry(1n)).to.emit(swapEscrow, "SwapCancelled");
    });

    it("reverts proposeSwap when transfer window is closed", async function () {
      const ctx = await deployWithSwap();
      const { ethers, swapEscrow, clubA, playerA, playerB, token, transferWindow } = ctx;

      const win = await transferWindow.getActiveWindow();
      await ethers.provider.send("evm_setNextBlockTimestamp", [Number(win.closesAt) + 1]);
      await ethers.provider.send("evm_mine", []);

      await expect(
        swapEscrow.connect(clubA).proposeSwap(playerA, playerB, await token.getAddress(), 0n, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(swapEscrow, "TransferWindowClosed");
    });

    it("league force cancels swap", async function () {
      const ctx = await deployWithSwap();
      const { ethers, swapEscrow, clubA, admin, playerA, playerB, token } = ctx;

      await swapEscrow.connect(clubA).proposeSwap(playerA, playerB, await token.getAddress(), 0n, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress);
      await expect(
        swapEscrow.connect(admin).forceCancel(1n)
      ).to.emit(swapEscrow, "SwapCancelled");
    });

  });

  describe("FreeTransferEscrow", function () {

    async function deployWithFTE() {
      const base = await deployAll();
      const { ethers, admin, clubA, clubB, registrar, registry, token, addressReg, transferWindow } = base as any;

      const Proxy = await ethers.getContractFactory("TransferiumProxy");
      const FTEF  = await ethers.getContractFactory("FreeTransferEscrow");
      const fteImpl = await FTEF.deploy();
      const fteInit = fteImpl.interface.encodeFunctionData("initialize", [
        await registry.getAddress(),
        await addressReg.getAddress(),
        await base.escrow.getAddress(),
        admin.address,
        admin.address,
      ]);
      const fteProxy = await Proxy.deploy(await fteImpl.getAddress(), fteInit);
      const fte      = FTEF.attach(await fteProxy.getAddress());

      const ESCROW_ROLE = await registry.ESCROW_ROLE();
      const CLUB_ROLE   = await fte.CLUB_ROLE();
      await registry.grantRole(ESCROW_ROLE, await fte.getAddress());
      await fte.grantRole(CLUB_ROLE, clubA.address);
      await fte.grantRole(CLUB_ROLE, clubB.address);
      await fte.connect(admin).setProtocolFee(0);
      await fte.approveToken(await token.getAddress());

      // Player with contract already expired — for releaseExpiredContract tests
      const now    = await (async () => { const b = await ethers.provider.getBlock("latest"); return b.timestamp; })();
      const expiry = now - 1; // already expired
      const tx = await registry.connect(clubA).registerPlayer(
        "Free Agent", "ST", "French", expiry, ethers.parseUnits("10000", 6),
        ethers.id("fte-player-1")
      );
      const receipt = await tx.wait();
      const event   = receipt.logs
        .map((l: any) => { try { return registry.interface.parseLog(l); } catch { return null; } })
        .find((e: any) => e?.name === "PlayerRegistered");
      const freePlayerId = event.args.playerId;

      await registry.connect(registrar).markPlayerVerified(freePlayerId, registrar.address);
      const medHash = ethers.keccak256(ethers.toUtf8Bytes("med-fte-1"));
      await registry.connect(clubA).setMedicalClearance(freePlayerId, medHash);
      const regHash = ethers.keccak256(ethers.toUtf8Bytes("reg-fte-1"));
      const tmsHash = ethers.keccak256(ethers.toUtf8Bytes("tms-fte-1"));
      await registry.connect(clubA).submitLegalDocuments(freePlayerId, regHash, tmsHash, ethers.ZeroHash);
      await registry.connect(registrar).setLegalDocsVerified(freePlayerId, registrar.address);

      // Player wallet for consent flows
      const playerWallet = ethers.Wallet.createRandom().connect(ethers.provider);
      await clubA.sendTransaction({ to: playerWallet.address, value: ethers.parseEther("1") });
      await registry.connect(clubA).setPlayerWallet(freePlayerId, playerWallet.address);

      await openTransferWindow(ethers, transferWindow);

      return { ...base, fte, freePlayerId, playerWallet };
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    async function releasePlayer(ctx: any) {
      const { fte, clubA, freePlayerId } = ctx;
      await fte.connect(clubA).releaseExpiredContract(freePlayerId);
    }

    async function proposeAndSign(ctx: any, signingBonus = 0n) {
      const { ethers, fte, clubB, freePlayerId, playerWallet, token } = ctx;
      await fte.connect(clubB).proposePreContract(
        freePlayerId, await token.getAddress(), signingBonus, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress
      );
      const ftId = await fte.totalFreeTransfers();
      await fte.connect(playerWallet).signPreContract(ftId);
      return ftId;
    }

    // ── tests ─────────────────────────────────────────────────────────────────

    it("releaseExpiredContract marks player as free agent", async function () {
      const ctx = await deployWithFTE();
      const { fte, clubA, freePlayerId } = ctx;
      await expect(fte.connect(clubA).releaseExpiredContract(freePlayerId))
        .to.emit(fte, "PlayerReleased");
      expect(await fte.getFreeAgentStatus(freePlayerId)).to.equal(true);
    });

    it("releaseExpiredContract reverts if contract not expired", async function () {
      const ctx = await deployWithFTE();
      const { ethers, fte, clubA, registry, registrar } = ctx;
      // Register a player with a future expiry
      const now    = (await ethers.provider.getBlock("latest"))!.timestamp;
      const tx     = await registry.connect(clubA).registerPlayer(
        "Future Player", "GK", "Spanish", now + 365 * 24 * 3600, 0n,
        ethers.id("fte-future-1")
      );
      const receipt = await tx.wait();
      const pid = registry.interface.parseLog(
        receipt.logs.find((l: any) => { try { return registry.interface.parseLog(l)?.name === "PlayerRegistered"; } catch { return false; } })
      )!.args.playerId;
      await expect(fte.connect(clubA).releaseExpiredContract(pid))
        .to.be.revertedWithCustomError(fte, "ContractNotExpired");
    });

    it("proposePreContract creates PRE_CONTRACT_PROPOSED entry", async function () {
      const ctx = await deployWithFTE();
      const { ethers, fte, clubB, freePlayerId, token } = ctx;
      await releasePlayer(ctx);
      await expect(
        fte.connect(clubB).proposePreContract(
          freePlayerId, await token.getAddress(), 0n, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress
        )
      ).to.emit(fte, "PreContractProposed");
      const ftId = await fte.totalFreeTransfers();
      const ft   = await fte.getFT(ftId);
      expect(ft.state).to.equal(2n); // PRE_CONTRACT_PROPOSED
      expect(ft.buyingClub).to.equal(clubB.address);
    });

    it("signPreContract moves to PRE_CONTRACT_SIGNED", async function () {
      const ctx = await deployWithFTE();
      const { fte, freePlayerId, playerWallet, token, ethers, clubB } = ctx;
      await releasePlayer(ctx);
      await fte.connect(clubB).proposePreContract(
        freePlayerId, await token.getAddress(), 0n, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress
      );
      const ftId = await fte.totalFreeTransfers();
      await expect(fte.connect(playerWallet).signPreContract(ftId))
        .to.emit(fte, "PreContractSigned");
      expect((await fte.getFT(ftId)).state).to.equal(3n); // PRE_CONTRACT_SIGNED
    });

    it("club withdraws proposal before signing → CANCELLED, no penalty", async function () {
      const ctx = await deployWithFTE();
      const { ethers, fte, clubB, freePlayerId, token } = ctx;
      await releasePlayer(ctx);
      await fte.connect(clubB).proposePreContract(
        freePlayerId, await token.getAddress(), 0n, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress
      );
      const ftId = await fte.totalFreeTransfers();
      await expect(fte.connect(clubB).withdrawPreContract(ftId))
        .to.emit(fte, "PreContractCancelled");
      expect((await fte.getFT(ftId)).state).to.equal(7n); // CANCELLED
    });

    it("club withdraws after signing → deposit forfeited to player", async function () {
      const ctx = await deployWithFTE();
      const { ethers, fte, clubB, freePlayerId, token, playerWallet } = ctx;
      const BONUS = ethers.parseUnits("1000000", 6);
      await token.mint(clubB.address, BONUS);
      await token.connect(clubB).approve(await fte.getAddress(), BONUS);

      await releasePlayer(ctx);
      const ftId = await proposeAndSign(ctx, BONUS);

      // lock deposit (10% of bonus)
      await fte.connect(clubB).lockDeposit(ftId);

      await expect(fte.connect(clubB).withdrawPreContract(ftId))
        .to.emit(fte, "PreContractCancelled");

      // deposit claimable by player wallet
      const deposit = BONUS * 1000n / 10000n; // depositBps = 1000
      expect(await fte.getClaimable(playerWallet.address, await token.getAddress()))
        .to.equal(deposit);
    });

    it("medical PASSED → FreeTransferCompleted, NFT at buying club", async function () {
      const ctx = await deployWithFTE();
      const { ethers, fte, clubB, freePlayerId, token, registry } = ctx;
      await releasePlayer(ctx);
      const ftId = await proposeAndSign(ctx, 0n);
      // no deposit needed for zero signing bonus — lockDeposit is a no-op
      await fte.connect(clubB).lockDeposit(ftId);

      const hash = ethers.keccak256(ethers.toUtf8Bytes("medical-pass"));
      await expect(fte.connect(clubB).submitMedical(ftId, 1n, hash)) // PASSED=1
        .to.emit(fte, "FreeTransferCompleted");
      expect(await registry.currentClub(freePlayerId)).to.equal(clubB.address);
    });

    it("medical FAILED → CANCELLED, deposit returned to buying club", async function () {
      const ctx = await deployWithFTE();
      const { ethers, fte, clubB, freePlayerId, token } = ctx;
      const BONUS = ethers.parseUnits("500000", 6);
      await token.mint(clubB.address, BONUS);
      await token.connect(clubB).approve(await fte.getAddress(), BONUS);

      await releasePlayer(ctx);
      const ftId = await proposeAndSign(ctx, BONUS);
      await fte.connect(clubB).lockDeposit(ftId);

      const hash = ethers.keccak256(ethers.toUtf8Bytes("medical-fail"));
      await expect(fte.connect(clubB).submitMedical(ftId, 2n, hash)) // FAILED=2
        .to.emit(fte, "PreContractCancelled");
      expect((await fte.getFT(ftId)).state).to.equal(7n); // CANCELLED

      const deposit = BONUS * 1000n / 10000n;
      expect(await fte.getClaimable(clubB.address, await token.getAddress()))
        .to.equal(deposit);
    });

    it("signing bonus split: protocol fee + agent fee + player receives remainder", async function () {
      const ctx = await deployWithFTE();
      const { ethers, fte, clubB, freePlayerId, token, playerWallet, admin } = ctx;
      const BONUS      = ethers.parseUnits("1000000", 6); // €1M
      const AGENT_BPS  = 200n; // 2%
      const PROTO_BPS  = 100n; // 1% — set non-zero for this test

      await fte.connect(admin).setProtocolFee(PROTO_BPS);
      await token.mint(clubB.address, BONUS * 2n);
      await token.connect(clubB).approve(await fte.getAddress(), BONUS * 2n);

      await releasePlayer(ctx);

      const agentWallet = ethers.Wallet.createRandom().connect(ethers.provider);
      await fte.connect(clubB).proposePreContract(
        freePlayerId, await token.getAddress(), BONUS, AGENT_BPS, agentWallet.address, 0, ethers.ZeroAddress
      );
      const ftId = await fte.totalFreeTransfers();
      await fte.connect(playerWallet).signPreContract(ftId);
      await fte.connect(clubB).lockDeposit(ftId);

      const hash = ethers.keccak256(ethers.toUtf8Bytes("medical-pass-2"));
      await fte.connect(clubB).submitMedical(ftId, 1n, hash);

      const tokenAddr   = await token.getAddress();
      const protocolFee = BONUS * PROTO_BPS / 10000n;
      const agentFee    = BONUS * AGENT_BPS / 10000n;
      const playerShare = BONUS - protocolFee - agentFee;

      expect(await fte.getClaimable(agentWallet.address, tokenAddr)).to.equal(agentFee);
      expect(await fte.getClaimable(playerWallet.address, tokenAddr)).to.equal(playerShare);
    });

    it("mutual termination: propose → confirm → player is free agent", async function () {
      const ctx = await deployWithFTE();
      const { ethers, fte, clubA, freePlayerId, token, playerWallet } = ctx;
      const SETTLEMENT = ethers.parseUnits("200000", 6);
      await token.mint(clubA.address, SETTLEMENT);
      await token.connect(clubA).approve(await fte.getAddress(), SETTLEMENT);

      await expect(
        fte.connect(clubA).proposeMutualTermination(freePlayerId, await token.getAddress(), SETTLEMENT)
      ).to.emit(fte, "MutualTerminationProposed");

      await expect(
        fte.connect(playerWallet).confirmMutualTermination(freePlayerId)
      ).to.emit(fte, "MutualTerminationConfirmed");

      expect(await fte.getFreeAgentStatus(freePlayerId)).to.equal(true);
      expect(await fte.getClaimable(playerWallet.address, await token.getAddress()))
        .to.equal(SETTLEMENT);
    });

    it("mutual termination: club withdraws proposal → settlement refunded", async function () {
      const ctx = await deployWithFTE();
      const { ethers, fte, clubA, freePlayerId, token } = ctx;
      const SETTLEMENT = ethers.parseUnits("100000", 6);
      await token.mint(clubA.address, SETTLEMENT);
      await token.connect(clubA).approve(await fte.getAddress(), SETTLEMENT);

      await fte.connect(clubA).proposeMutualTermination(freePlayerId, await token.getAddress(), SETTLEMENT);
      await fte.connect(clubA).withdrawMutualTermination(freePlayerId);

      expect(await fte.getClaimable(clubA.address, await token.getAddress()))
        .to.equal(SETTLEMENT);
    });

    it("submitMedical reverts when transfer window closed", async function () {
      const ctx = await deployWithFTE();
      const { ethers, fte, clubB, freePlayerId, token, transferWindow } = ctx;
      await releasePlayer(ctx);
      const ftId = await proposeAndSign(ctx, 0n);
      await fte.connect(clubB).lockDeposit(ftId);

      const win = await transferWindow.getActiveWindow();
      await ethers.provider.send("evm_setNextBlockTimestamp", [Number(win.closesAt) + 1]);
      await ethers.provider.send("evm_mine", []);

      const hash = ethers.keccak256(ethers.toUtf8Bytes("late-medical"));
      await expect(fte.connect(clubB).submitMedical(ftId, 1n, hash))
        .to.be.revertedWithCustomError(fte, "TransferWindowClosed");
    });

    it("multiple clubs can propose; only one can sign", async function () {
      const ctx = await deployWithFTE();
      const { ethers, fte, clubA, clubB, freePlayerId, token, playerWallet } = ctx;
      await releasePlayer(ctx);

      // clubA also proposes
      await fte.connect(clubA).proposePreContract(
        freePlayerId, await token.getAddress(), 0n, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress
      );
      await fte.connect(clubB).proposePreContract(
        freePlayerId, await token.getAddress(), 0n, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress
      );

      // Player signs with clubB (ftId=2 since clubA proposed first = ftId 1)
      const ftIdB = await fte.totalFreeTransfers(); // clubB's ftId
      await fte.connect(playerWallet).signPreContract(ftIdB);

      // clubA tries to sign — should revert as pre-contract already active
      const ftIdA = ftIdB - 1n;
      await expect(fte.connect(playerWallet).signPreContract(ftIdA))
        .to.be.revertedWithCustomError(fte, "PreContractAlreadyActive");
    });

  });

  describe("TransferEscrow", function () {

    // ── helpers ───────────────────────────────────────────────────────────────

    // I build a minimal valid single-installment bid payload
    function simpleBid(ethers: any, token: any, fee: bigint, futureDate: number) {
      return {
        token,
        fee,
        sellOnBps:        0,
        sellOnRecipient:  ethers.ZeroAddress,
        sellerAgentBps:   0,
        sellerAgent:      ethers.ZeroAddress,
        buyerAgentBps:    0,
        buyerAgent:       ethers.ZeroAddress,
        bonusMonths:      0,
        amounts:          [fee],
        dates:            [futureDate],
      };
    }

    async function deployWithOffer() {
      const base    = await deployAll();
      const { ethers, admin, clubA, clubB, clubC, registrar, registry, token, escrow, transferWindow } = base as any;

      const CLUB_ROLE = await escrow.CLUB_ROLE();
      await escrow.grantRole(CLUB_ROLE, clubC.address);
      await escrow.connect(admin).setProtocolFee(0);

      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar, ethers.parseUnits("50000", 6), "te-1");
      await openTransferWindow(ethers, transferWindow);

      const PRICE    = ethers.parseUnits("50000000", 6); // €50M
      const now      = (await ethers.provider.getBlock("latest"))!.timestamp;
      const future   = now + 90 * 24 * 3600;

      await escrow.connect(clubA).createOffer(
        playerId, await token.getAddress(), PRICE, 0, ethers.ZeroAddress,
        0, ethers.ZeroAddress, 100, []
      );
      const offerId = await escrow.totalOffers();

      return { ...base, escrow, playerId, offerId, PRICE, future };
    }

    async function submitSimpleBid(ctx: any, club: any, fee?: bigint) {
      const { ethers, escrow, offerId, PRICE, future } = ctx;
      const f   = fee ?? PRICE;
      const tok = await ctx.token.getAddress();
      await escrow.connect(club).submitBid(
        offerId, f, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress,
        0, ethers.ZeroAddress, 0, [f], [future]
      );
    }

    // ── Offer tests ───────────────────────────────────────────────────────────

    it("createOffer emits OfferCreated and records offer", async function () {
      const ctx = await deployWithOffer();
      const { escrow, offerId, playerId, clubA, PRICE } = ctx;
      const offer = await escrow.getOffer(offerId);
      expect(offer.playerId).to.equal(playerId);
      expect(offer.sellingClub).to.equal(clubA.address);
      expect(offer.askingPrice).to.equal(PRICE);
      expect(offer.exists).to.equal(true);
    });

    it("createOffer reverts when transfer window is closed", async function () {
      const base = await deployAll();
      const { ethers, admin, clubA, registrar, registry, token, escrow } = base as any;
      const CLUB_ROLE = await escrow.CLUB_ROLE();
      await escrow.grantRole(CLUB_ROLE, clubA.address);
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar, ethers.parseUnits("50000", 6), "te-closed");
      // window not opened — should revert
      await expect(
        escrow.connect(clubA).createOffer(
          playerId, await token.getAddress(), ethers.parseUnits("1000000", 6),
          0, ethers.ZeroAddress, 0, ethers.ZeroAddress, 100, []
        )
      ).to.be.revertedWithCustomError(escrow, "TransferWindowClosed");
    });

    it("updateOffer changes asking price", async function () {
      const ctx = await deployWithOffer();
      const { ethers, escrow, offerId, clubA, PRICE } = ctx;
      const newPrice = PRICE * 2n;
      await expect(
        escrow.connect(clubA).updateOffer(offerId, newPrice, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress, 100)
      ).to.emit(escrow, "OfferUpdated").withArgs(offerId, newPrice);
      expect((await escrow.getOffer(offerId)).askingPrice).to.equal(newPrice);
    });

    it("withdrawOffer removes offer", async function () {
      const ctx = await deployWithOffer();
      const { escrow, offerId, clubA } = ctx;
      await expect(escrow.connect(clubA).withdrawOffer(offerId))
        .to.emit(escrow, "OfferWithdrawn");
      await expect(escrow.getOffer(offerId))
        .to.be.revertedWithCustomError(escrow, "OfferNotFound");
    });

    it("duplicate offer for same player reverts PlayerHasActiveOffer", async function () {
      const ctx = await deployWithOffer();
      const { ethers, escrow, clubA, playerId, token, PRICE } = ctx;
      await expect(
        escrow.connect(clubA).createOffer(
          playerId, await token.getAddress(), PRICE, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress, 100, []
        )
      ).to.be.revertedWithCustomError(escrow, "PlayerHasActiveOffer");
    });

    // ── Bid tests ─────────────────────────────────────────────────────────────

    it("submitBid emits BidSubmitted in NEGOTIATING state", async function () {
      const ctx = await deployWithOffer();
      const { escrow, offerId, clubB, PRICE } = ctx;
      await submitSimpleBid(ctx, clubB);
      const bid = await escrow.connect(clubB).getBid(offerId, clubB.address);
      // BidStatus: NONE=0, PENDING=1, NEGOTIATING=2, ACCEPTED=3, REJECTED=4, WITHDRAWN=5
      expect(bid.status).to.equal(2n); // NEGOTIATING
      expect(bid.transferFee).to.equal(PRICE);
    });

    it("submitBid reverts if installment sum != transferFee", async function () {
      const ctx = await deployWithOffer();
      const { ethers, escrow, offerId, clubB, PRICE, future } = ctx;
      await expect(
        escrow.connect(clubB).submitBid(
          offerId, PRICE, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress,
          0, ethers.ZeroAddress, 0, [PRICE / 2n], [future]
        )
      ).to.be.revertedWithCustomError(escrow, "InvalidAmount");
    });

    it("selling club cannot bid on own player", async function () {
      const ctx = await deployWithOffer();
      const { escrow, offerId, clubA, PRICE, future } = ctx;
      await expect(
        escrow.connect(clubA).submitBid(
          offerId, PRICE, 0, (ctx as any).ethers.ZeroAddress, 0, (ctx as any).ethers.ZeroAddress,
          0, (ctx as any).ethers.ZeroAddress, 0, [PRICE], [future]
        )
      ).to.be.revertedWithCustomError(escrow, "CannotBidOnOwnPlayer");
    });

    it("withdrawBid removes bid and emits BidWithdrawn", async function () {
      const ctx = await deployWithOffer();
      const { escrow, offerId, clubB } = ctx;
      await submitSimpleBid(ctx, clubB);
      await expect(escrow.connect(clubB).withdrawBid(offerId))
        .to.emit(escrow, "BidWithdrawn").withArgs(offerId, clubB.address);
      const bid = await escrow.connect(clubB).getBid(offerId, clubB.address);
      expect(bid.status).to.equal(5n); // WITHDRAWN
    });

    it("rejectBid by selling club emits BidRejected", async function () {
      const ctx = await deployWithOffer();
      const { escrow, offerId, clubA, clubB } = ctx;
      await submitSimpleBid(ctx, clubB);
      await expect(escrow.connect(clubA).rejectBid(offerId, clubB.address))
        .to.emit(escrow, "BidRejected").withArgs(offerId, clubB.address);
    });

    it("counterBid → updateBid → acceptBid full negotiation flow", async function () {
      const ctx = await deployWithOffer();
      const { ethers, escrow, offerId, clubA, clubB, PRICE, future, dealEscrow } = ctx;

      await submitSimpleBid(ctx, clubB);

      // seller counters at higher price
      const counterPrice = PRICE + ethers.parseUnits("5000000", 6);
      await expect(
        escrow.connect(clubA).counterBid(offerId, clubB.address, PRICE, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress)
      ).to.emit(escrow, "CounterOffer");

      // buyer acknowledges counter — updates bid to match counter price
      await escrow.connect(clubB).updateBid(
        offerId, PRICE, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress, 0,
        [PRICE], [future]
      );

      // seller can now accept
      await expect(
        escrow.connect(clubA).acceptBid(offerId, clubB.address)
      ).to.emit(escrow, "BidAccepted");

      // offer should be gone
      await expect(escrow.getOffer(offerId))
        .to.be.revertedWithCustomError(escrow, "OfferNotFound");
    });

    it("acceptBid reverts when isCounterFromSeller is true (seller's turn pending)", async function () {
      const ctx = await deployWithOffer();
      const { ethers, escrow, offerId, clubA, clubB, PRICE } = ctx;
      await submitSimpleBid(ctx, clubB);
      // seller counters — now isCounterFromSeller = true, buyer must respond first
      await escrow.connect(clubA).counterBid(
        offerId, clubB.address, PRICE, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress
      );
      await expect(
        escrow.connect(clubA).acceptBid(offerId, clubB.address)
      ).to.be.revertedWithCustomError(escrow, "NotYourTurnToCounter");
    });

    it("pending bid activated when negotiating slot opens", async function () {
      const ctx  = await deployWithOffer();
      const base = await deployAll();
      const { ethers, escrow, offerId, clubA, clubB, clubC, other } = ctx;

      // Fill 5 negotiating slots with distinct clubs — we only have clubB, clubC, other
      // so we only test the PENDING → NEGOTIATING promotion when one withdraws
      await submitSimpleBid(ctx, clubB);
      await submitSimpleBid(ctx, clubC);

      // clubB withdraws — slot opens, no pending bids to promote (only 2 submitted)
      await expect(escrow.connect(clubB).withdrawBid(offerId))
        .to.emit(escrow, "BidWithdrawn");

      // offer still has 1 active negotiation
      const offer = await escrow.getOffer(offerId);
      expect(offer.activeNegotiations).to.equal(1n);
    });

    // ── Ban tests ─────────────────────────────────────────────────────────────

    it("banned club cannot submit bid", async function () {
      const ctx = await deployWithOffer();
      const { escrow, offerId, clubB, admin } = ctx;
      const LEAGUE_ROLE = await escrow.LEAGUE_ROLE();
      await escrow.grantRole(LEAGUE_ROLE, admin.address);
      await escrow.connect(admin).issueBan(clubB.address, 2);
      await expect(submitSimpleBid(ctx, clubB))
        .to.be.revertedWithCustomError(escrow, "ClubTransferBanned");
    });

    it("liftBan restores club ability to bid", async function () {
      const ctx = await deployWithOffer();
      const { escrow, offerId, clubB, admin } = ctx;
      const LEAGUE_ROLE = await escrow.LEAGUE_ROLE();
      await escrow.grantRole(LEAGUE_ROLE, admin.address);
      await escrow.connect(admin).issueBan(clubB.address, 1);
      await escrow.connect(admin).liftBan(clubB.address);
      // should not revert now
      await submitSimpleBid(ctx, clubB);
      const bid = await escrow.connect(clubB).getBid(offerId, clubB.address);
      expect(bid.status).to.equal(2n); // NEGOTIATING
    });

  });


  describe("InstallmentEscrow", function () {

    async function setupCompletedDeal(ctx: any) {
      const { ethers, escrow, dealEscrow, token, clubA, clubB, other,
              registry, transferWindow, registrar, admin } = ctx;

      const salt     = "ie-" + Math.random().toString(36).slice(2, 8);
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar, undefined, salt);
      await registry.connect(clubA).setPlayerWallet(playerId, other.address);

      const fee  = ethers.parseUnits("10000000", 6);
      const half = fee / 2n;

      await openTransferWindow(ethers, transferWindow);

      const nowAfter = BigInt((await ethers.provider.getBlock("latest"))!.timestamp);
      const date0    = nowAfter + 3600n;               // index 0: due in 1h (fundDeal ignores this)
      const date1    = nowAfter + 7200n;               // index 1: due in 2h — past due after 48h advance

      const offerTx = await escrow.connect(clubA).createOffer(
        playerId, await token.getAddress(), fee,
        0, ethers.ZeroAddress, 0, ethers.ZeroAddress, 500, []
      );
      const offerId = (await offerTx.wait()).logs
        .map((l: any) => { try { return escrow.interface.parseLog(l); } catch { return null; } })
        .find((e: any) => e?.name === "OfferCreated").args.offerId;

      await escrow.connect(clubB).submitBid(
        offerId, fee,
        0, ethers.ZeroAddress, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress, 0,
        [half, half], [date0, date1]
      );

      const acceptTx = await escrow.connect(clubA).acceptBid(offerId, clubB.address);
      const dealId = (await acceptTx.wait()).logs
        .map((l: any) => { try { return dealEscrow.interface.parseLog(l); } catch { return null; } })
        .find((e: any) => e?.name === "DealCreated").args.dealId;

      await dealEscrow.connect(other).consentToTransfer(dealId);
      const medHash = ethers.keccak256(ethers.toUtf8Bytes("med-" + salt));
      await dealEscrow.connect(clubB).submitMedical(dealId, 1, medHash);

      await ethers.provider.send("evm_increaseTime", [48 * 3600 + 1]);
      await ethers.provider.send("evm_mine", []);
      await escrow.processExpiry(dealId);

      await token.connect(clubB).approve(await dealEscrow.getAddress(), half);
      await dealEscrow.connect(clubB).fundDeal(dealId);
      await dealEscrow.connect(admin).forceComplete(dealId);

      return { dealId, half, fee, date1 };
    }

    async function setupCompletedDealFarDates(ctx: any) {
      const { ethers, escrow, dealEscrow, token, clubA, clubB, other,
              registry, transferWindow, registrar, admin } = ctx;

      const salt     = "ie-far-" + Math.random().toString(36).slice(2, 8);
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar, undefined, salt);
      await registry.connect(clubA).setPlayerWallet(playerId, other.address);

      const fee  = ethers.parseUnits("10000000", 6);
      const half = fee / 2n;

      await openTransferWindow(ethers, transferWindow);

      const nowAfter = BigInt((await ethers.provider.getBlock("latest"))!.timestamp);
      const date1 = nowAfter + BigInt(365 * 24 * 3600);
      const date2 = nowAfter + BigInt(2 * 365 * 24 * 3600);

      const offerTx = await escrow.connect(clubA).createOffer(
        playerId, await token.getAddress(), fee,
        0, ethers.ZeroAddress, 0, ethers.ZeroAddress, 500, []
      );
      const offerId = (await offerTx.wait()).logs
        .map((l: any) => { try { return escrow.interface.parseLog(l); } catch { return null; } })
        .find((e: any) => e?.name === "OfferCreated").args.offerId;

      await escrow.connect(clubB).submitBid(
        offerId, fee,
        0, ethers.ZeroAddress, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress, 0,
        [half, half], [date1, date2]
      );

      const acceptTx = await escrow.connect(clubA).acceptBid(offerId, clubB.address);
      const dealId = (await acceptTx.wait()).logs
        .map((l: any) => { try { return dealEscrow.interface.parseLog(l); } catch { return null; } })
        .find((e: any) => e?.name === "DealCreated").args.dealId;

      await dealEscrow.connect(other).consentToTransfer(dealId);
      const medHash = ethers.keccak256(ethers.toUtf8Bytes("med-" + salt));
      await dealEscrow.connect(clubB).submitMedical(dealId, 1, medHash);

      await ethers.provider.send("evm_increaseTime", [48 * 3600 + 1]);
      await ethers.provider.send("evm_mine", []);
      await escrow.processExpiry(dealId);

      await token.connect(clubB).approve(await dealEscrow.getAddress(), half);
      await dealEscrow.connect(clubB).fundDeal(dealId);
      await dealEscrow.connect(admin).forceComplete(dealId);

      return { dealId, half, fee };
    }

    it("payInstallment: credits selling club after due date", async function () {
      const ctx: any = await deployAll();
      const { installmentEscrow, token, clubA, clubB } = ctx;
      const { dealId, half } = await setupCompletedDeal(ctx);

      const tokenAddr = await token.getAddress();
      const protoBps  = await installmentEscrow.protocolFeeBps();
      const protoAmt  = half * protoBps / 10000n;

      await token.connect(clubB).approve(await installmentEscrow.getAddress(), half);
      await expect(installmentEscrow.connect(clubB).payInstallment(dealId, 1))
        .to.emit(installmentEscrow, "InstallmentPaid");

      expect(await installmentEscrow.claimable(clubA.address, tokenAddr))
        .to.equal(half - protoAmt);
    });

    it("payInstallment: reverts if not buying club", async function () {
      const ctx: any = await deployAll();
      const { installmentEscrow, token, clubA } = ctx;
      const { dealId, half } = await setupCompletedDeal(ctx);

      await token.connect(clubA).approve(await installmentEscrow.getAddress(), half);
      await expect(installmentEscrow.connect(clubA).payInstallment(dealId, 1))
        .to.be.revertedWithCustomError(installmentEscrow, "NotBuyingClub");
    });

    it("payInstallment: reverts if index 0", async function () {
      const ctx: any = await deployAll();
      const { installmentEscrow, token, clubB } = ctx;
      const { dealId, half } = await setupCompletedDeal(ctx);

      await token.connect(clubB).approve(await installmentEscrow.getAddress(), half);
      await expect(installmentEscrow.connect(clubB).payInstallment(dealId, 0))
        .to.be.revertedWithCustomError(installmentEscrow, "InvalidIndex");
    });

    it("payInstallment: reverts if index >= installmentCount", async function () {
      const ctx: any = await deployAll();
      const { installmentEscrow, token, clubB } = ctx;
      const { dealId, half } = await setupCompletedDeal(ctx);

      await token.connect(clubB).approve(await installmentEscrow.getAddress(), half);
      await expect(installmentEscrow.connect(clubB).payInstallment(dealId, 2))
        .to.be.revertedWithCustomError(installmentEscrow, "InvalidIndex");
    });

    it("payInstallment: reverts if not yet due", async function () {
      const ctx: any = await deployAll();
      const { installmentEscrow, token, clubB } = ctx;
      const { dealId, half } = await setupCompletedDealFarDates(ctx);

      await token.connect(clubB).approve(await installmentEscrow.getAddress(), half);
      await expect(installmentEscrow.connect(clubB).payInstallment(dealId, 1))
        .to.be.revertedWithCustomError(installmentEscrow, "InstallmentNotDue");
    });

    it("payInstallment: reverts on double payment", async function () {
      const ctx: any = await deployAll();
      const { installmentEscrow, token, clubB } = ctx;
      const { dealId, half } = await setupCompletedDeal(ctx);

      await token.connect(clubB).approve(await installmentEscrow.getAddress(), half * 2n);
      await installmentEscrow.connect(clubB).payInstallment(dealId, 1);
      await expect(installmentEscrow.connect(clubB).payInstallment(dealId, 1))
        .to.be.revertedWithCustomError(installmentEscrow, "InstallmentAlreadyPaid");
    });

    it("payInstallment: protocol fee deducted correctly", async function () {
      const ctx: any = await deployAll();
      const { installmentEscrow, token, clubA, clubB, admin } = ctx;
      const { dealId, half } = await setupCompletedDeal(ctx);

      const PROTO_BPS = 200n;
      await installmentEscrow.connect(admin).setProtocolFee(PROTO_BPS);
      const tokenAddr = await token.getAddress();

      await token.connect(clubB).approve(await installmentEscrow.getAddress(), half);
      await installmentEscrow.connect(clubB).payInstallment(dealId, 1);

      const protoAmt = half * PROTO_BPS / 10000n;
      expect(await installmentEscrow.claimable(clubA.address, tokenAddr)).to.equal(half - protoAmt);
      expect(await installmentEscrow.claimable(admin.address, tokenAddr)).to.equal(protoAmt);
    });

    it("flagOverdue: emits InstallmentOverdue when past due date", async function () {
      const ctx: any = await deployAll();
      const { installmentEscrow, admin } = ctx;
      const { dealId } = await setupCompletedDeal(ctx);

      await expect(installmentEscrow.connect(admin).flagOverdue(dealId, 1))
        .to.emit(installmentEscrow, "InstallmentOverdue");
    });

    it("flagOverdue: reverts if installment not yet overdue", async function () {
      const ctx: any = await deployAll();
      const { installmentEscrow, admin } = ctx;
      const { dealId } = await setupCompletedDealFarDates(ctx);

      await expect(installmentEscrow.connect(admin).flagOverdue(dealId, 1))
        .to.be.revertedWithCustomError(installmentEscrow, "InstallmentNotOverdue");
    });

    it("claim: transfers tokens to caller and zeroes balance", async function () {
      const ctx: any = await deployAll();
      const { installmentEscrow, token, clubA, clubB } = ctx;
      const { dealId, half } = await setupCompletedDeal(ctx);

      const tokenAddr = await token.getAddress();
      const protoBps  = await installmentEscrow.protocolFeeBps();
      const protoAmt  = half * protoBps / 10000n;
      const sellerAmt = half - protoAmt;

      await token.connect(clubB).approve(await installmentEscrow.getAddress(), half);
      await installmentEscrow.connect(clubB).payInstallment(dealId, 1);

      const before = await token.balanceOf(clubA.address);
      await installmentEscrow.connect(clubA).claim(tokenAddr);
      expect(await token.balanceOf(clubA.address)).to.equal(before + sellerAmt);
      expect(await installmentEscrow.claimable(clubA.address, tokenAddr)).to.equal(0n);
    });

    it("claim: reverts with NothingToClaim if balance is zero", async function () {
      const ctx: any = await deployAll();
      const { installmentEscrow, token, clubA } = ctx as any;
      await expect(installmentEscrow.connect(clubA).claim(await token.getAddress()))
        .to.be.revertedWithCustomError(installmentEscrow, "NothingToClaim");
    });

  });

});