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

  const MockToken = await ethers.getContractFactory("MockERC20");
  const token = await MockToken.deploy("Mock USDC", "mUSDC", 6);

  const PlayerRegistry = await ethers.getContractFactory("PlayerRegistry");
  const registry = await PlayerRegistry.deploy(
    ethers.parseEther("0.01"),
    ethers.parseEther("0.005")
  );

  const TransferWindow = await ethers.getContractFactory("TransferWindow");
  const transferWindow = await TransferWindow.deploy();

  const TransferEscrow = await ethers.getContractFactory("TransferEscrow");
  const escrow = await TransferEscrow.deploy(
    await registry.getAddress(),
    await transferWindow.getAddress()
  );

  const LoanEscrow = await ethers.getContractFactory("LoanEscrow");
  const loanEscrow = await LoanEscrow.deploy(
    await registry.getAddress(),
    await transferWindow.getAddress()
  );

  const CLUB_ROLE      = await registry.CLUB_ROLE();
  const REGISTRAR_ROLE = await registry.REGISTRAR_ROLE();
  const ESCROW_ROLE    = await registry.ESCROW_ROLE();
  const LEAGUE_ROLE    = await escrow.LEAGUE_ROLE();

  await registry.grantRole(CLUB_ROLE, clubA.address);
  await registry.grantRole(CLUB_ROLE, clubB.address);
  await registry.grantRole(REGISTRAR_ROLE, registrar.address);
  await registry.grantRole(ESCROW_ROLE, await escrow.getAddress());
  await registry.grantRole(ESCROW_ROLE, await loanEscrow.getAddress());

  await escrow.grantRole(CLUB_ROLE, clubA.address);
  await escrow.grantRole(CLUB_ROLE, clubB.address);
  await loanEscrow.grantRole(CLUB_ROLE, clubA.address);
  await loanEscrow.grantRole(CLUB_ROLE, clubB.address);

  await escrow.approveToken(await token.getAddress());
  await loanEscrow.approveToken(await token.getAddress());

  await token.mint(clubB.address, ethers.parseUnits("1000000000", 6));
  await token.mint(clubA.address, ethers.parseUnits("1000000000", 6));

  return {
    ethers,
    admin, registrar, clubA, clubB, clubC, other,
    token, registry, transferWindow, escrow, loanEscrow,
    CLUB_ROLE, REGISTRAR_ROLE, ESCROW_ROLE, LEAGUE_ROLE,
  };
}

async function setupListedPlayer(ethers: any, registry: any, club: any, registrar: any): Promise<bigint> {
  const now = await getChainTime(ethers);
  const expiry = now + 365 * 24 * 3600;

  const tx = await registry.connect(club).registerPlayer(
    "Kylian Mbappe", "ST", "French", expiry,
    { value: ethers.parseEther("0.01") }
  );
  const receipt = await tx.wait();
  const event = receipt.logs
    .map((log: any) => { try { return registry.interface.parseLog(log); } catch { return null; } })
    .find((e: any) => e?.name === "PlayerRegistered");
  const playerId = event.args.playerId;

  await registry.connect(registrar).verifyPlayer(playerId);
  await registry.connect(club).listPlayer(
    playerId,
    ethers.parseUnits("50000000", 6),
    { value: ethers.parseEther("0.005") }
  );

  return playerId;
}

async function openTransferWindow(ethers: any, transferWindow: any): Promise<void> {
  const now = await getChainTime(ethers);
  await transferWindow.scheduleWindow("Summer 2025", now + 10, now + 30 * 24 * 3600);
  await ethers.provider.send("evm_increaseTime", [11]);
  await ethers.provider.send("evm_mine", []);
  await transferWindow.advanceActiveWindow();
}

// ─── Tests ────────────────────────────────────────────────────────────────────

describe("Transferium Protocol", function () {

  // ── PlayerRegistry ──────────────────────────────────────────────────────────
  describe("PlayerRegistry", function () {

    it("registers a player and emits PlayerRegistered", async function () {
      const { ethers, registry, clubA } = await deployAll();
      const now = await getChainTime(ethers);

      await expect(
        registry.connect(clubA).registerPlayer(
          "Erling Haaland", "ST", "Norwegian", now + 365 * 24 * 3600,
          { value: ethers.parseEther("0.01") }
        )
      ).to.emit(registry, "PlayerRegistered");
    });

    it("reverts registration with wrong fee", async function () {
      const { ethers, registry, clubA } = await deployAll();
      const now = await getChainTime(ethers);

      await expect(
        registry.connect(clubA).registerPlayer(
          "Erling Haaland", "ST", "Norwegian", now + 365 * 24 * 3600,
          { value: 0 }
        )
      ).to.be.revertedWithCustomError(registry, "InsufficientPayment");
    });

    it("reverts duplicate player registration from same club", async function () {
      const { ethers, registry, clubA } = await deployAll();
      const now = await getChainTime(ethers);
      const expiry = now + 365 * 24 * 3600;
      const fee = ethers.parseEther("0.01");

      await registry.connect(clubA).registerPlayer("Erling Haaland", "ST", "Norwegian", expiry, { value: fee });
      await expect(
        registry.connect(clubA).registerPlayer("Erling Haaland", "ST", "Norwegian", expiry, { value: fee })
      ).to.be.revertedWithCustomError(registry, "PlayerAlreadyExists");
    });

    it("reverts registration without CLUB_ROLE", async function () {
      const { ethers, registry, other } = await deployAll();
      const now = await getChainTime(ethers);

      await expect(
        registry.connect(other).registerPlayer(
          "Test Player", "GK", "Nigerian", now + 365 * 24 * 3600,
          { value: ethers.parseEther("0.01") }
        )
      ).to.be.revertedWithCustomError(registry, "AccessControlUnauthorizedAccount");
    });

    it("verifies a player and emits PlayerVerified", async function () {
      const { ethers, registry, clubA, registrar } = await deployAll();
      const now = await getChainTime(ethers);

      const tx = await registry.connect(clubA).registerPlayer(
        "Test", "CM", "English", now + 365 * 24 * 3600,
        { value: ethers.parseEther("0.01") }
      );
      const receipt = await tx.wait();
      const event = receipt.logs
        .map((log: any) => { try { return registry.interface.parseLog(log); } catch { return null; } })
        .find((e: any) => e?.name === "PlayerRegistered");
      const playerId = event.args.playerId;

      await expect(registry.connect(registrar).verifyPlayer(playerId))
        .to.emit(registry, "PlayerVerified");
    });

    it("reverts listing an unverified player", async function () {
      const { ethers, registry, clubA } = await deployAll();
      const now = await getChainTime(ethers);

      const tx = await registry.connect(clubA).registerPlayer(
        "Test", "CM", "English", now + 365 * 24 * 3600,
        { value: ethers.parseEther("0.01") }
      );
      const receipt = await tx.wait();
      const event = receipt.logs
        .map((log: any) => { try { return registry.interface.parseLog(log); } catch { return null; } })
        .find((e: any) => e?.name === "PlayerRegistered");
      const playerId = event.args.playerId;

      await expect(
        registry.connect(clubA).listPlayer(
          playerId, ethers.parseUnits("1000000", 6),
          { value: ethers.parseEther("0.005") }
        )
      ).to.be.revertedWithCustomError(registry, "PlayerNotVerified");
    });

    it("withdrawFees enforces MAX_WITHDRAW cap", async function () {
      const { ethers, registry, admin } = await deployAll();

      await expect(
        registry.withdrawFees(admin.address, ethers.parseEther("2000"))
      ).to.be.revertedWithCustomError(registry, "WithdrawAmountTooLarge");
    });
  });

  // ── TransferWindow ───────────────────────────────────────────────────────────
  describe("TransferWindow", function () {

    it("schedules a window and reports isWindowOpen correctly", async function () {
      const { ethers, transferWindow } = await deployAll();
      const now = await getChainTime(ethers);

      expect(await transferWindow.isWindowOpen()).to.be.false;

      await transferWindow.scheduleWindow("Summer 2025", now + 10, now + 30 * 24 * 3600);
      await ethers.provider.send("evm_increaseTime", [11]);
      await ethers.provider.send("evm_mine", []);

      expect(await transferWindow.isWindowOpen()).to.be.true;
    });

    it("reverts scheduling overlapping windows", async function () {
      const { ethers, transferWindow } = await deployAll();
      const now = await getChainTime(ethers);

      await transferWindow.scheduleWindow("Summer 2025", now + 100, now + 200);
      await expect(
        transferWindow.scheduleWindow("Overlap", now + 150, now + 300)
      ).to.be.revertedWithCustomError(transferWindow, "WindowOverlap");
    });

    it("reverts cancelling an already open window", async function () {
      const { ethers, transferWindow } = await deployAll();
      const now = await getChainTime(ethers);

      const tx = await transferWindow.scheduleWindow("Summer 2025", now + 10, now + 30 * 24 * 3600);
      const receipt = await tx.wait();
      const event = receipt.logs
        .map((log: any) => { try { return transferWindow.interface.parseLog(log); } catch { return null; } })
        .find((e: any) => e?.name === "WindowScheduled");
      const windowId = event.args.windowId;

      await ethers.provider.send("evm_increaseTime", [11]);
      await ethers.provider.send("evm_mine", []);

      await expect(
        transferWindow.cancelWindow(windowId)
      ).to.be.revertedWithCustomError(transferWindow, "WindowAlreadyClosed");
    });

    it("extends an open window", async function () {
      const { ethers, transferWindow } = await deployAll();
      const now = await getChainTime(ethers);
      const closeAt = now + 30 * 24 * 3600;

      const tx = await transferWindow.scheduleWindow("Summer 2025", now + 10, closeAt);
      const receipt = await tx.wait();
      const event = receipt.logs
        .map((log: any) => { try { return transferWindow.interface.parseLog(log); } catch { return null; } })
        .find((e: any) => e?.name === "WindowScheduled");
      const windowId = event.args.windowId;

      await ethers.provider.send("evm_increaseTime", [11]);
      await ethers.provider.send("evm_mine", []);

      await expect(
        transferWindow.extendWindow(windowId, closeAt + 5 * 24 * 3600)
      ).to.emit(transferWindow, "WindowExtended");
    });
  });

  // ── TransferEscrow ───────────────────────────────────────────────────────────
  describe("TransferEscrow", function () {

    it("reverts createDeal outside transfer window", async function () {
      const { ethers, registry, transferWindow, escrow, token, clubA, clubB, registrar } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar);

      const fee = ethers.parseUnits("50000000", 6);
      await token.connect(clubB).approve(await escrow.getAddress(), fee);

      await expect(
        escrow.connect(clubB).createDeal(
          playerId, clubA.address, await token.getAddress(), fee, 0, ethers.ZeroAddress
        )
      ).to.be.revertedWithCustomError(escrow, "TransferWindowClosed");
    });

    it("creates a deal during open window and emits DealCreated", async function () {
      const { ethers, registry, transferWindow, escrow, token, clubA, clubB, registrar } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar);
      await openTransferWindow(ethers, transferWindow);

      const fee = ethers.parseUnits("50000000", 6);
      await token.connect(clubB).approve(await escrow.getAddress(), fee);

      await expect(
        escrow.connect(clubB).createDeal(
          playerId, clubA.address, await token.getAddress(), fee, 0, ethers.ZeroAddress
        )
      ).to.emit(escrow, "DealCreated");
    });

    it("reverts createDeal with unregistered selling club", async function () {
      const { ethers, registry, transferWindow, escrow, token, clubA, clubB, registrar, CLUB_ROLE } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar);
      await openTransferWindow(ethers, transferWindow);
      await registry.revokeRole(CLUB_ROLE, clubA.address);

      const fee = ethers.parseUnits("50000000", 6);
      await token.connect(clubB).approve(await escrow.getAddress(), fee);

      await expect(
        escrow.connect(clubB).createDeal(
          playerId, clubA.address, await token.getAddress(), fee, 0, ethers.ZeroAddress
        )
      ).to.be.revertedWithCustomError(escrow, "SellingClubNotRegistered");
    });

    it("full deal flow: create → approve → claimFunds → ownership transferred", async function () {
      const { ethers, registry, transferWindow, escrow, token, clubA, clubB, registrar } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar);
      await openTransferWindow(ethers, transferWindow);

      const fee = ethers.parseUnits("50000000", 6);
      await token.connect(clubB).approve(await escrow.getAddress(), fee);

      const tx = await escrow.connect(clubB).createDeal(
        playerId, clubA.address, await token.getAddress(), fee, 0, ethers.ZeroAddress
      );
      const receipt = await tx.wait();
      const event = receipt.logs
        .map((log: any) => { try { return escrow.interface.parseLog(log); } catch { return null; } })
        .find((e: any) => e?.name === "DealCreated");
      const dealId = event.args.dealId;

      await escrow.approveDeal(dealId);

      await ethers.provider.send("evm_increaseTime", [48 * 3600 + 1]);
      await ethers.provider.send("evm_mine", []);

      await expect(escrow.connect(clubA).claimFunds(dealId))
        .to.emit(escrow, "DealCompleted");

      const player = await registry.getPlayer(playerId);
      expect(player.currentClub).to.equal(clubB.address);

      await expect(escrow.connect(clubA).withdrawClaimable(await token.getAddress()))
        .to.emit(escrow, "FundsClaimed");
    });

    it("claimFunds reverts before dispute window expires", async function () {
      const { ethers, registry, transferWindow, escrow, token, clubA, clubB, registrar } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar);
      await openTransferWindow(ethers, transferWindow);

      const fee = ethers.parseUnits("50000000", 6);
      await token.connect(clubB).approve(await escrow.getAddress(), fee);

      const tx = await escrow.connect(clubB).createDeal(
        playerId, clubA.address, await token.getAddress(), fee, 0, ethers.ZeroAddress
      );
      const receipt = await tx.wait();
      const event = receipt.logs
        .map((log: any) => { try { return escrow.interface.parseLog(log); } catch { return null; } })
        .find((e: any) => e?.name === "DealCreated");
      const dealId = event.args.dealId;

      await escrow.approveDeal(dealId);

      await expect(
        escrow.connect(clubA).claimFunds(dealId)
      ).to.be.revertedWithCustomError(escrow, "DisputeWindowActive");
    });

    it("rejected deal allows buying club to reclaim funds", async function () {
      const { ethers, registry, transferWindow, escrow, token, clubA, clubB, registrar } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar);
      await openTransferWindow(ethers, transferWindow);

      const fee = ethers.parseUnits("50000000", 6);
      await token.connect(clubB).approve(await escrow.getAddress(), fee);

      const tx = await escrow.connect(clubB).createDeal(
        playerId, clubA.address, await token.getAddress(), fee, 0, ethers.ZeroAddress
      );
      const receipt = await tx.wait();
      const event = receipt.logs
        .map((log: any) => { try { return escrow.interface.parseLog(log); } catch { return null; } })
        .find((e: any) => e?.name === "DealCreated");
      const dealId = event.args.dealId;

      await escrow.rejectDeal(dealId, "Player ineligible");

      await expect(
        escrow.connect(clubB).withdrawClaimable(await token.getAddress())
      ).to.emit(escrow, "FundsClaimed");
    });

    it("sell-on clause splits payment correctly", async function () {
      const { ethers, registry, transferWindow, escrow, token, clubA, clubB, clubC, registrar } = await deployAll();
      await escrow.grantRole(await escrow.CLUB_ROLE(), clubC.address);

      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar);
      await openTransferWindow(ethers, transferWindow);

      const fee = ethers.parseUnits("50000000", 6);
      const sellOnBps = 500;
      await token.connect(clubB).approve(await escrow.getAddress(), fee);

      const tx = await escrow.connect(clubB).createDeal(
        playerId, clubA.address, await token.getAddress(), fee, sellOnBps, clubC.address
      );
      const receipt = await tx.wait();
      const event = receipt.logs
        .map((log: any) => { try { return escrow.interface.parseLog(log); } catch { return null; } })
        .find((e: any) => e?.name === "DealCreated");
      const dealId = event.args.dealId;

      await escrow.approveDeal(dealId);
      await ethers.provider.send("evm_increaseTime", [48 * 3600 + 1]);
      await ethers.provider.send("evm_mine", []);
      await escrow.connect(clubA).claimFunds(dealId);

      const sellOnAmount = fee * BigInt(sellOnBps) / BigInt(10000);
      const sellerAmount = fee - sellOnAmount;

      expect(await escrow.getClaimable(clubA.address, await token.getAddress())).to.equal(sellerAmount);
      expect(await escrow.getClaimable(clubC.address, await token.getAddress())).to.equal(sellOnAmount);
    });
  });

  // ── LoanEscrow ───────────────────────────────────────────────────────────────
  describe("LoanEscrow", function () {

    it("creates a loan deal and emits LoanCreated", async function () {
      const { ethers, registry, transferWindow, loanEscrow, token, clubA, clubB, registrar } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar);
      await openTransferWindow(ethers, transferWindow);

      const loanFee = ethers.parseUnits("1000000", 6);
      await token.connect(clubB).approve(await loanEscrow.getAddress(), loanFee);

      await expect(
        loanEscrow.connect(clubB).createLoan(
          playerId, clubA.address, await token.getAddress(),
          loanFee, 90 * 24 * 3600, false, 0
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
        playerId, clubA.address, await token.getAddress(),
        loanFee, duration, false, 0
      );
      const receipt = await tx.wait();
      const event = receipt.logs
        .map((log: any) => { try { return loanEscrow.interface.parseLog(log); } catch { return null; } })
        .find((e: any) => e?.name === "LoanCreated");
      const loanId = event.args.loanId;

      await loanEscrow.approveLoan(loanId);
      let player = await registry.getPlayer(playerId);
      expect(player.currentClub).to.equal(clubB.address);

      await ethers.provider.send("evm_increaseTime", [48 * 3600 + 1]);
      await ethers.provider.send("evm_mine", []);
      await expect(loanEscrow.connect(clubA).claimLoanFee(loanId))
        .to.emit(loanEscrow, "LoanFeeClaimed");

      await ethers.provider.send("evm_increaseTime", [duration]);
      await ethers.provider.send("evm_mine", []);
      await expect(loanEscrow.connect(clubA).settleLoanExpiry(loanId))
        .to.emit(loanEscrow, "LoanExpired");

      player = await registry.getPlayer(playerId);
      expect(player.currentClub).to.equal(clubA.address);
    });

    it("recall flow: requestRecall → enforce notice period → executeRecall", async function () {
      const { ethers, registry, transferWindow, loanEscrow, token, clubA, clubB, registrar } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar);
      await openTransferWindow(ethers, transferWindow);

      const loanFee = ethers.parseUnits("1000000", 6);
      const duration = 180 * 24 * 3600;
      await token.connect(clubB).approve(await loanEscrow.getAddress(), loanFee);

      const tx = await loanEscrow.connect(clubB).createLoan(
        playerId, clubA.address, await token.getAddress(),
        loanFee, duration, false, 0
      );
      const receipt = await tx.wait();
      const event = receipt.logs
        .map((log: any) => { try { return loanEscrow.interface.parseLog(log); } catch { return null; } })
        .find((e: any) => e?.name === "LoanCreated");
      const loanId = event.args.loanId;

      await loanEscrow.approveLoan(loanId);
      await loanEscrow.connect(clubA).requestRecall(loanId);

      await expect(
        loanEscrow.connect(clubA).executeRecall(loanId)
      ).to.be.revertedWithCustomError(loanEscrow, "RecallNoticeNotMet");

      await ethers.provider.send("evm_increaseTime", [14 * 24 * 3600 + 1]);
      await ethers.provider.send("evm_mine", []);

      await expect(loanEscrow.connect(clubA).executeRecall(loanId))
        .to.emit(loanEscrow, "LoanRecalled");

      const player = await registry.getPlayer(playerId);
      expect(player.currentClub).to.equal(clubA.address);
    });

    it("option to buy: exercise converts loan to permanent transfer", async function () {
      const { ethers, registry, transferWindow, loanEscrow, token, clubA, clubB, registrar } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar);
      await openTransferWindow(ethers, transferWindow);

      const loanFee     = ethers.parseUnits("1000000", 6);
      const optionPrice = ethers.parseUnits("40000000", 6);
      const duration    = 180 * 24 * 3600;

      await token.connect(clubB).approve(await loanEscrow.getAddress(), loanFee);

      const tx = await loanEscrow.connect(clubB).createLoan(
        playerId, clubA.address, await token.getAddress(),
        loanFee, duration, true, optionPrice
      );
      const receipt = await tx.wait();
      const event = receipt.logs
        .map((log: any) => { try { return loanEscrow.interface.parseLog(log); } catch { return null; } })
        .find((e: any) => e?.name === "LoanCreated");
      const loanId = event.args.loanId;

      await loanEscrow.approveLoan(loanId);

      await token.connect(clubB).approve(await loanEscrow.getAddress(), optionPrice);
      await expect(loanEscrow.connect(clubB).exerciseOption(loanId))
        .to.emit(loanEscrow, "OptionExercised");

      const player = await registry.getPlayer(playerId);
      expect(player.currentClub).to.equal(clubB.address);

      expect(await loanEscrow.getClaimable(clubA.address, await token.getAddress()))
        .to.equal(optionPrice);
    });

    it("third party cannot trigger settleLoanExpiry", async function () {
      const { ethers, registry, transferWindow, loanEscrow, token, clubA, clubB, other, registrar } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar);
      await openTransferWindow(ethers, transferWindow);

      const loanFee = ethers.parseUnits("1000000", 6);
      const duration = 30 * 24 * 3600;
      await token.connect(clubB).approve(await loanEscrow.getAddress(), loanFee);

      const tx = await loanEscrow.connect(clubB).createLoan(
        playerId, clubA.address, await token.getAddress(),
        loanFee, duration, false, 0
      );
      const receipt = await tx.wait();
      const event = receipt.logs
        .map((log: any) => { try { return loanEscrow.interface.parseLog(log); } catch { return null; } })
        .find((e: any) => e?.name === "LoanCreated");
      const loanId = event.args.loanId;

      await loanEscrow.approveLoan(loanId);

      await ethers.provider.send("evm_increaseTime", [duration + 1]);
      await ethers.provider.send("evm_mine", []);

      await expect(
        loanEscrow.connect(other).settleLoanExpiry(loanId)
      ).to.be.revertedWithCustomError(loanEscrow, "NotAuthorised");
    });
  });
});
