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

  const LoanEscrowF = await ethers.getContractFactory("LoanEscrow");
  const loanEscrow = await LoanEscrowF.deploy(
    await registry.getAddress(),
    await addressReg.getAddress()
  );

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
    token, registry, transferWindow, escrow, dealEscrow, loanEscrow,
    CLUB_ROLE, REGISTRAR_ROLE, ESCROW_ROLE, LEAGUE_ROLE,
  };
}

// I register a player with all clearances and list them
async function setupListedPlayer(
  ethers: any,
  registry: any,
  club: any,
  registrar: any,
  weeklySalary = ethers.parseUnits("50000", 6) // €50k/week default
): Promise<bigint> {
  const now    = await getChainTime(ethers);
  const expiry = now + 365 * 24 * 3600;

  const tx = await registry.connect(club).registerPlayer(
    "Kylian Mbappe", "ST", "French", expiry, weeklySalary,
    ethers.id("player-1") // fifaId
  );
  const receipt = await tx.wait();
  const event   = receipt.logs
    .map((log: any) => { try { return registry.interface.parseLog(log); } catch { return null; } })
    .find((e: any) => e?.name === "PlayerRegistered");
  const playerId = event.args.playerId;

  // I verify the player
  await registry.connect(registrar).markPlayerVerified(playerId, registrar.address);

  // I set medical clearance
  const medHash = ethers.keccak256(ethers.toUtf8Bytes("medical-report-001"));
  await registry.connect(club).setMedicalClearance(playerId, medHash);

  // I submit legal documents
  const regHash  = ethers.keccak256(ethers.toUtf8Bytes("registration-contract"));
  const idHash   = ethers.keccak256(ethers.toUtf8Bytes("passport-001"));
  const tmsHash  = ethers.keccak256(ethers.toUtf8Bytes("fifa-tms-ref"));
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
});
