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
  const token = await MockToken.deploy("Mock EURC", "mEURC", 6);

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
    { value: ethers.parseEther("0.01") }
  );
  const receipt = await tx.wait();
  const event   = receipt.logs
    .map((log: any) => { try { return registry.interface.parseLog(log); } catch { return null; } })
    .find((e: any) => e?.name === "PlayerRegistered");
  const playerId = event.args.playerId;

  // I verify the player
  await registry.connect(registrar).verifyPlayer(playerId);

  // I set medical clearance
  const medHash = ethers.keccak256(ethers.toUtf8Bytes("medical-report-001"));
  await registry.connect(registrar).setMedicalClearance(playerId, medHash);

  // I submit legal documents
  const regHash  = ethers.keccak256(ethers.toUtf8Bytes("registration-contract"));
  const idHash   = ethers.keccak256(ethers.toUtf8Bytes("passport-001"));
  const tmsHash  = ethers.keccak256(ethers.toUtf8Bytes("fifa-tms-ref"));
  await registry.connect(club).submitLegalDocuments(playerId, regHash, idHash, tmsHash, ethers.ZeroHash);

  // I verify legal documents
  await registry.connect(registrar).verifyLegalDocuments(playerId);

  // I list the player
  await registry.connect(club).listPlayer(
    playerId,
    ethers.parseUnits("50000000", 6),
    { value: ethers.parseEther("0.005") }
  );

  return playerId;
}

async function openTransferWindow(ethers: any, transferWindow: any): Promise<void> {
  const now = await getChainTime(ethers);
  await transferWindow.scheduleWindow("Summer 2026", now + 10, now + 30 * 24 * 3600);
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
  salaryGuaranteeMonths = 0
): Promise<bigint> {
  const fee = ethers.parseUnits("50000000", 6);

  // I compute salary guarantee if needed
  const player = await (await ethers.getContractAt(
    ["function getPlayer(uint256) external view returns (tuple(uint256,string,string,string,uint256,uint256,address,bool,bool,bool,bytes32,uint256,uint256,uint256))"],
    await (await ethers.getContractFactory("PlayerRegistry")).attach
  ));

  // I approve fee + potential guarantee
  const guaranteeAmount = salaryGuaranteeMonths > 0
    ? ethers.parseUnits("50000", 6) * BigInt(4) * BigInt(salaryGuaranteeMonths)
    : BigInt(0);

  await token.connect(buyingClub).approve(await escrow.getAddress(), fee + guaranteeAmount);

  const tx = await escrow.connect(buyingClub).createDeal(
    playerId,
    sellingClub.address,
    await token.getAddress(),
    fee,
    salaryGuaranteeMonths,
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
        { value: ethers.parseEther("0.01") }
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

    it("reverts registration with wrong fee", async function () {
      const { ethers, registry, clubA } = await deployAll();
      const now = await getChainTime(ethers);
      await expect(
        registry.connect(clubA).registerPlayer("Test", "ST", "English", now + 365 * 24 * 3600, 0, { value: 0 })
      ).to.be.revertedWithCustomError(registry, "InsufficientPayment");
    });

    it("reverts duplicate registration from same club", async function () {
      const { ethers, registry, clubA } = await deployAll();
      const now    = await getChainTime(ethers);
      const expiry = now + 365 * 24 * 3600;
      const fee    = ethers.parseEther("0.01");
      await registry.connect(clubA).registerPlayer("Erling Haaland", "ST", "Norwegian", expiry, 0, { value: fee });
      await expect(
        registry.connect(clubA).registerPlayer("Erling Haaland", "ST", "Norwegian", expiry, 0, { value: fee })
      ).to.be.revertedWithCustomError(registry, "PlayerAlreadyExists");
    });

    it("reverts registration without CLUB_ROLE", async function () {
      const { ethers, registry, other } = await deployAll();
      const now = await getChainTime(ethers);
      await expect(
        registry.connect(other).registerPlayer("Test", "GK", "Nigerian", now + 365 * 24 * 3600, 0, { value: ethers.parseEther("0.01") })
      ).to.be.revertedWithCustomError(registry, "AccessControlUnauthorizedAccount");
    });

    it("verifies a player", async function () {
      const { ethers, registry, clubA, registrar } = await deployAll();
      const now = await getChainTime(ethers);
      const tx      = await registry.connect(clubA).registerPlayer("Test", "CM", "English", now + 365 * 24 * 3600, 0, { value: ethers.parseEther("0.01") });
      const receipt = await tx.wait();
      const event   = receipt.logs.map((log: any) => { try { return registry.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "PlayerRegistered");
      await expect(registry.connect(registrar).verifyPlayer(event.args.playerId)).to.emit(registry, "PlayerVerified");
    });

    it("reverts listing without medical clearance", async function () {
      const { ethers, registry, clubA, registrar } = await deployAll();
      const now = await getChainTime(ethers);
      const tx      = await registry.connect(clubA).registerPlayer("Test", "CM", "English", now + 365 * 24 * 3600, 0, { value: ethers.parseEther("0.01") });
      const receipt = await tx.wait();
      const event   = receipt.logs.map((log: any) => { try { return registry.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "PlayerRegistered");
      const playerId = event.args.playerId;
      await registry.connect(registrar).verifyPlayer(playerId);
      await expect(
        registry.connect(clubA).listPlayer(playerId, ethers.parseUnits("1000000", 6), { value: ethers.parseEther("0.005") })
      ).to.be.revertedWithCustomError(registry, "MedicalClearanceRequired");
    });

    it("reverts listing without legal docs verified", async function () {
      const { ethers, registry, clubA, registrar } = await deployAll();
      const now = await getChainTime(ethers);
      const tx      = await registry.connect(clubA).registerPlayer("Test", "CM", "English", now + 365 * 24 * 3600, 0, { value: ethers.parseEther("0.01") });
      const receipt = await tx.wait();
      const event   = receipt.logs.map((log: any) => { try { return registry.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "PlayerRegistered");
      const playerId = event.args.playerId;
      await registry.connect(registrar).verifyPlayer(playerId);
      const medHash = ethers.keccak256(ethers.toUtf8Bytes("medical"));
      await registry.connect(registrar).setMedicalClearance(playerId, medHash);
      await expect(
        registry.connect(clubA).listPlayer(playerId, ethers.parseUnits("1000000", 6), { value: ethers.parseEther("0.005") })
      ).to.be.revertedWithCustomError(registry, "LegalDocsNotVerified");
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
      const tx      = await registry.connect(clubA).registerPlayer("Test", "GK", "Nigerian", now + 365 * 24 * 3600, 0, { value: ethers.parseEther("0.01") });
      const receipt = await tx.wait();
      const event   = receipt.logs.map((log: any) => { try { return registry.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "PlayerRegistered");
      await expect(
        registry.connect(clubA).transferFrom(clubA.address, clubB.address, event.args.playerId)
      ).to.be.revertedWithCustomError(registry, "DirectTransferBlocked");
    });

    it("registrar sets player wallet, player can update it", async function () {
      const { ethers, registry, clubA, clubB, registrar, other } = await deployAll();
      const now = await getChainTime(ethers);
      const tx      = await registry.connect(clubA).registerPlayer("Test", "ST", "Brazilian", now + 365 * 24 * 3600, 0, { value: ethers.parseEther("0.01") });
      const receipt = await tx.wait();
      const event   = receipt.logs.map((log: any) => { try { return registry.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "PlayerRegistered");
      const playerId = event.args.playerId;

      // I set player wallet as registrar
      await expect(registry.connect(registrar).setPlayerWallet(playerId, other.address))
        .to.emit(registry, "PlayerWalletSet");

      let player = await registry.getPlayer(playerId);
      expect(player.playerWallet).to.equal(other.address);

      // I update player wallet from the player's own wallet
      const newWallet = clubB.address;
      await expect(registry.connect(other).updatePlayerWallet(playerId, newWallet))
        .to.emit(registry, "PlayerWalletUpdated");

      player = await registry.getPlayer(playerId);
      expect(player.playerWallet).to.equal(newWallet);
    });

    it("reverts player wallet update from wrong address", async function () {
      const { ethers, registry, clubA, clubB, registrar, other } = await deployAll();
      const now = await getChainTime(ethers);
      const tx      = await registry.connect(clubA).registerPlayer("Test", "ST", "Brazilian", now + 365 * 24 * 3600, 0, { value: ethers.parseEther("0.01") });
      const receipt = await tx.wait();
      const event   = receipt.logs.map((log: any) => { try { return registry.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "PlayerRegistered");
      const playerId = event.args.playerId;

      await registry.connect(registrar).setPlayerWallet(playerId, other.address);

      // I attempt update from wrong wallet — should revert
      await expect(
        registry.connect(clubB).updatePlayerWallet(playerId, clubB.address)
      ).to.be.revertedWithCustomError(registry, "NotPlayerWallet");
    });

    it("extends player contract", async function () {
      const { ethers, registry, clubA } = await deployAll();
      const now    = await getChainTime(ethers);
      const expiry = now + 365 * 24 * 3600;
      const tx      = await registry.connect(clubA).registerPlayer("Test", "CM", "English", expiry, 0, { value: ethers.parseEther("0.01") });
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
      const tx      = await registry.connect(clubA).registerPlayer("Test", "ST", "Brazilian", now + 365 * 24 * 3600, 0, { value: ethers.parseEther("0.01") });
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
        registry.withdrawFees(admin.address, ethers.parseEther("2000"))
      ).to.be.revertedWithCustomError(registry, "WithdrawAmountTooLarge");
    });
  });

  describe("TransferWindow", function () {

    it("schedules a window and reports isWindowOpen correctly", async function () {
      const { ethers, transferWindow } = await deployAll();
      const now = await getChainTime(ethers);
      expect(await transferWindow.isWindowOpen()).to.be.false;
      await transferWindow.scheduleWindow("Summer 2026", now + 10, now + 30 * 24 * 3600);
      await ethers.provider.send("evm_increaseTime", [11]);
      await ethers.provider.send("evm_mine", []);
      expect(await transferWindow.isWindowOpen()).to.be.true;
    });

    it("reverts scheduling overlapping windows", async function () {
      const { ethers, transferWindow } = await deployAll();
      const now = await getChainTime(ethers);
      await transferWindow.scheduleWindow("Summer 2026", now + 100, now + 200);
      await expect(
        transferWindow.scheduleWindow("Overlap", now + 150, now + 300)
      ).to.be.revertedWithCustomError(transferWindow, "WindowOverlap");
    });

    it("reverts cancelling an already open window", async function () {
      const { ethers, transferWindow } = await deployAll();
      const now     = await getChainTime(ethers);
      const tx      = await transferWindow.scheduleWindow("Summer 2026", now + 10, now + 30 * 24 * 3600);
      const receipt = await tx.wait();
      const event   = receipt.logs.map((log: any) => { try { return transferWindow.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "WindowScheduled");
      await ethers.provider.send("evm_increaseTime", [11]);
      await ethers.provider.send("evm_mine", []);
      await expect(transferWindow.cancelWindow(event.args.windowId))
        .to.be.revertedWithCustomError(transferWindow, "WindowAlreadyClosed");
    });

    it("extends an open window", async function () {
      const { ethers, transferWindow } = await deployAll();
      const now     = await getChainTime(ethers);
      const closeAt = now + 30 * 24 * 3600;
      const tx      = await transferWindow.scheduleWindow("Summer 2026", now + 10, closeAt);
      const receipt = await tx.wait();
      const event   = receipt.logs.map((log: any) => { try { return transferWindow.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "WindowScheduled");
      await ethers.provider.send("evm_increaseTime", [11]);
      await ethers.provider.send("evm_mine", []);
      await expect(transferWindow.extendWindow(event.args.windowId, closeAt + 5 * 24 * 3600))
        .to.emit(transferWindow, "WindowExtended");
    });
  });

  describe("TransferEscrow", function () {

    it("reverts createDeal outside transfer window", async function () {
      const { ethers, registry, escrow, token, clubA, clubB, registrar } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar);
      const fee = ethers.parseUnits("50000000", 6);
      await token.connect(clubB).approve(await escrow.getAddress(), fee);
      await expect(
        escrow.connect(clubB).createDeal(
          playerId, clubA.address, await token.getAddress(), fee,
          0, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress, []
        )
      ).to.be.revertedWithCustomError(escrow, "TransferWindowClosed");
    });

    it("creates a deal during open window", async function () {
      const { ethers, registry, transferWindow, escrow, token, clubA, clubB, registrar } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar);
      await openTransferWindow(ethers, transferWindow);
      const fee = ethers.parseUnits("50000000", 6);
      await token.connect(clubB).approve(await escrow.getAddress(), fee);
      await expect(
        escrow.connect(clubB).createDeal(
          playerId, clubA.address, await token.getAddress(), fee,
          0, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress, []
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
          playerId, clubA.address, await token.getAddress(), fee,
          0, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress, []
        )
      ).to.be.revertedWithCustomError(escrow, "SellingClubNotRegistered");
    });

    it("full deal flow: create → approve → claimFunds → NFT transferred", async function () {
      const { ethers, registry, transferWindow, escrow, token, clubA, clubB, registrar } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar);
      await openTransferWindow(ethers, transferWindow);

      const fee = ethers.parseUnits("50000000", 6);
      await token.connect(clubB).approve(await escrow.getAddress(), fee);
      const tx = await escrow.connect(clubB).createDeal(
        playerId, clubA.address, await token.getAddress(), fee,
        0, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress, []
      );
      const receipt = await tx.wait();
      const event   = receipt.logs.map((log: any) => { try { return escrow.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "DealCreated");
      const dealId  = event.args.dealId;

      await escrow.approveDeal(dealId);
      await ethers.provider.send("evm_increaseTime", [48 * 3600 + 1]);
      await ethers.provider.send("evm_mine", []);

      await expect(escrow.connect(clubA).claimFunds(dealId)).to.emit(escrow, "DealCompleted");
      expect(await registry.ownerOf(playerId)).to.equal(clubB.address);
      expect(await registry.currentClub(playerId)).to.equal(clubB.address);
      await expect(escrow.connect(clubA).withdrawClaimable(await token.getAddress())).to.emit(escrow, "FundsClaimed");
    });

    it("claimFunds reverts before dispute window expires", async function () {
      const { ethers, registry, transferWindow, escrow, token, clubA, clubB, registrar } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar);
      await openTransferWindow(ethers, transferWindow);
      const fee = ethers.parseUnits("50000000", 6);
      await token.connect(clubB).approve(await escrow.getAddress(), fee);
      const tx = await escrow.connect(clubB).createDeal(
        playerId, clubA.address, await token.getAddress(), fee,
        0, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress, []
      );
      const receipt = await tx.wait();
      const event   = receipt.logs.map((log: any) => { try { return escrow.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "DealCreated");
      await escrow.approveDeal(event.args.dealId);
      await expect(escrow.connect(clubA).claimFunds(event.args.dealId))
        .to.be.revertedWithCustomError(escrow, "DisputeWindowActive");
    });

    it("rejected deal refunds buying club", async function () {
      const { ethers, registry, transferWindow, escrow, token, clubA, clubB, registrar } = await deployAll();
      const playerId = await setupListedPlayer(ethers, registry, clubA, registrar);
      await openTransferWindow(ethers, transferWindow);
      const fee = ethers.parseUnits("50000000", 6);
      await token.connect(clubB).approve(await escrow.getAddress(), fee);
      const tx = await escrow.connect(clubB).createDeal(
        playerId, clubA.address, await token.getAddress(), fee,
        0, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress, []
      );
      const receipt = await tx.wait();
      const event   = receipt.logs.map((log: any) => { try { return escrow.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "DealCreated");
      await escrow.rejectDeal(event.args.dealId, "Player ineligible");
      await expect(escrow.connect(clubB).withdrawClaimable(await token.getAddress()))
        .to.emit(escrow, "FundsClaimed");
    });

    it("sell-on clause splits payment correctly", async function () {
      const { ethers, registry, transferWindow, escrow, token, clubA, clubB, clubC, registrar } = await deployAll();
      await escrow.grantRole(await escrow.CLUB_ROLE(), clubC.address);
      const playerId  = await setupListedPlayer(ethers, registry, clubA, registrar);
      await openTransferWindow(ethers, transferWindow);
      const fee       = ethers.parseUnits("50000000", 6);
      const sellOnBps = 500;
      await token.connect(clubB).approve(await escrow.getAddress(), fee);
      const tx = await escrow.connect(clubB).createDeal(
        playerId, clubA.address, await token.getAddress(), fee,
        0, sellOnBps, clubC.address, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress, []
      );
      const receipt = await tx.wait();
      const event   = receipt.logs.map((log: any) => { try { return escrow.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "DealCreated");
      const dealId  = event.args.dealId;
      await escrow.approveDeal(dealId);
      await ethers.provider.send("evm_increaseTime", [48 * 3600 + 1]);
      await ethers.provider.send("evm_mine", []);
      await escrow.connect(clubA).claimFunds(dealId);
      const sellOnAmount = fee * BigInt(sellOnBps) / BigInt(10000);
      expect(await escrow.getClaimable(clubA.address, await token.getAddress())).to.equal(fee - sellOnAmount);
      expect(await escrow.getClaimable(clubC.address, await token.getAddress())).to.equal(sellOnAmount);
    });

    it("agent fees split correctly", async function () {
      const { ethers, registry, transferWindow, escrow, token, clubA, clubB, clubC, other, registrar } = await deployAll();
      const playerId       = await setupListedPlayer(ethers, registry, clubA, registrar);
      await openTransferWindow(ethers, transferWindow);
      const fee            = ethers.parseUnits("50000000", 6);
      const sellerAgentBps = 300;
      const buyerAgentBps  = 200;
      await token.connect(clubB).approve(await escrow.getAddress(), fee);
      const tx = await escrow.connect(clubB).createDeal(
        playerId, clubA.address, await token.getAddress(), fee,
        0, 0, ethers.ZeroAddress, sellerAgentBps, clubC.address, buyerAgentBps, other.address, []
      );
      const receipt = await tx.wait();
      const event   = receipt.logs.map((log: any) => { try { return escrow.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "DealCreated");
      const dealId  = event.args.dealId;
      await escrow.approveDeal(dealId);
      await ethers.provider.send("evm_increaseTime", [48 * 3600 + 1]);
      await ethers.provider.send("evm_mine", []);
      await escrow.connect(clubA).claimFunds(dealId);
      const sellerAgentAmt = fee * BigInt(sellerAgentBps) / BigInt(10000);
      const buyerAgentAmt  = fee * BigInt(buyerAgentBps)  / BigInt(10000);
      expect(await escrow.getClaimable(clubA.address,  await token.getAddress())).to.equal(fee - sellerAgentAmt - buyerAgentAmt);
      expect(await escrow.getClaimable(clubC.address,  await token.getAddress())).to.equal(sellerAgentAmt);
      expect(await escrow.getClaimable(other.address,  await token.getAddress())).to.equal(buyerAgentAmt);
    });

    it("performance add-on routed to player wallet", async function () {
      const { ethers, registry, transferWindow, escrow, token, clubA, clubB, other, registrar } = await deployAll();
      const weeklySalary = ethers.parseUnits("50000", 6);
      const playerId     = await setupListedPlayer(ethers, registry, clubA, registrar, weeklySalary);

      // I set player wallet
      await registry.connect(registrar).setPlayerWallet(playerId, other.address);

      await openTransferWindow(ethers, transferWindow);

      const fee      = ethers.parseUnits("50000000", 6);
      const addOnAmt = ethers.parseUnits("2000000", 6); // €2M goal bonus
      await token.connect(clubB).approve(await escrow.getAddress(), fee);

      const tx = await escrow.connect(clubB).createDeal(
        playerId, clubA.address, await token.getAddress(), fee,
        0, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress,
        [{ description: "15+ league goals", amount: addOnAmt, toPlayer: true, triggered: false }]
      );
      const receipt = await tx.wait();
      const event   = receipt.logs.map((log: any) => { try { return escrow.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "DealCreated");
      const dealId  = event.args.dealId;

      await escrow.approveDeal(dealId);
      await ethers.provider.send("evm_increaseTime", [48 * 3600 + 1]);
      await ethers.provider.send("evm_mine", []);
      await escrow.connect(clubA).claimFunds(dealId);

      // I approve and trigger the add-on
      await token.connect(clubB).approve(await escrow.getAddress(), addOnAmt);
      await expect(escrow.triggerAddOn(dealId, 0)).to.emit(escrow, "AddOnTriggered");

      // I verify add-on went to player wallet, not selling club
      expect(await escrow.getClaimable(other.address, await token.getAddress())).to.equal(addOnAmt);
      expect(await escrow.getClaimable(clubA.address, await token.getAddress())).to.equal(fee);
    });

    it("salary guarantee locked in escrow, player can claim", async function () {
      const { ethers, registry, transferWindow, escrow, token, clubA, clubB, other, registrar } = await deployAll();
      const weeklySalary = ethers.parseUnits("50000", 6); // €50k/week
      const playerId     = await setupListedPlayer(ethers, registry, clubA, registrar, weeklySalary);

      // I set player wallet
      await registry.connect(registrar).setPlayerWallet(playerId, other.address);

      await openTransferWindow(ethers, transferWindow);

      const fee                   = ethers.parseUnits("50000000", 6);
      const salaryGuaranteeMonths = 3;
      // guarantee = €50k * 4 weeks * 3 months = €600k
      const guaranteeAmount = weeklySalary * BigInt(4) * BigInt(salaryGuaranteeMonths);
      const totalApprove    = fee + guaranteeAmount;

      await token.connect(clubB).approve(await escrow.getAddress(), totalApprove);

      const tx = await escrow.connect(clubB).createDeal(
        playerId, clubA.address, await token.getAddress(), fee,
        salaryGuaranteeMonths, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress, 0, ethers.ZeroAddress, []
      );
      const receipt = await tx.wait();
      const event   = receipt.logs.map((log: any) => { try { return escrow.interface.parseLog(log); } catch { return null; } }).find((e: any) => e?.name === "DealCreated");
      const dealId  = event.args.dealId;

      // I verify guarantee amount stored in deal
      const deal = await escrow.getDeal(dealId);
      expect(deal.salaryGuaranteeAmount).to.equal(guaranteeAmount);

      await escrow.approveDeal(dealId);
      await ethers.provider.send("evm_increaseTime", [48 * 3600 + 1]);
      await ethers.provider.send("evm_mine", []);
      await escrow.connect(clubA).claimFunds(dealId);

      // I claim salary guarantee from player wallet
      await expect(escrow.connect(other).claimSalaryGuarantee(dealId))
        .to.emit(escrow, "SalaryGuaranteeClaimed");

      expect(await escrow.getClaimable(other.address, await token.getAddress()))
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
  });
});
