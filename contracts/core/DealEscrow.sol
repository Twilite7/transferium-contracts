// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../base/ProtocolFeeBase.sol";

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IPlayerRegistry.sol";
import "../interfaces/ITransferWindow.sol";
import "../interfaces/IAddressRegistry.sol";
import "../utils/RegistryKeys.sol";
import "../interfaces/IDealEscrow.sol";
import "../libraries/FeeLib.sol";
import "../types/TransferTypes.sol";

contract DealEscrow is
    ProtocolFeeBase,
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;
    uint256 private _reentrancyStatus;

    modifier nonReentrant() {
        if (_reentrancyStatus == _ENTERED) revert ReentrantCall();
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }

    bytes32 public constant ADMIN_ROLE           = keccak256("ADMIN_ROLE");
    bytes32 public constant LEAGUE_ROLE          = keccak256("LEAGUE_ROLE");
    bytes32 public constant TRANSFER_ESCROW_ROLE = keccak256("TRANSFER_ESCROW_ROLE");

    uint256 internal constant MAX_PRICE                = 500_000_000 ether;
    uint256 internal constant BPS_DENOMINATOR          = 10_000;
    uint256 internal constant HIJACK_FAIL_PENALTY_BPS  = 200;
    uint256 internal constant HIJACK_STALL_PENALTY_BPS = 500;
    uint256 internal constant LEAGUE_DISPUTE_DEADLINE  = 7 days;
    uint256 internal constant MIN_TIMER = 10 seconds;

    struct Deal {
        uint256  offerId;
        uint256  playerId;
        address  sellingClub;
        address  buyingClub;
        address  paymentToken;
        uint256  transferFee;
        uint256  sellOnBps;
        address  sellOnRecipient;
        uint256  sellerAgentBps;
        address  sellerAgent;
        uint256  buyerAgentBps;
        address  buyerAgent;
        uint256  signingBonusMonths;
        uint256  signingBonusAmount;
        bool     signingBonusClaimed;
        uint256  signingBonusExpiry;   // timestamp after which league can rescue unclaimed bonus
        uint256  minimumHijackIncrementBps;
        TransferTypes.DealState      state;
        uint256  stateDeadline;
        uint256  acceptedAt;
        uint256  fundedAt;
        bytes32  medicalHash;
        TransferTypes.MedicalOutcome medicalOutcome;
        bool     frozen;
        uint256  frozenAt;
        uint256  hijackDeposit;
        address  hijackDepositClub;
        address  mutualCancelProposer;
        uint256  mutualCancelDeadline;
        // Installment schedule
        uint8    installmentCount;   // 1 = lump sum
        uint8    installmentsPaid;   // how many installments paid so far
    }

    struct HijackBid {
        address buyingClub;
        uint256 transferFee;
        uint256 buyerAgentBps;
        address buyerAgent;
        uint256 signingBonusMonths;
        uint256 depositedAt;
        bool    exists;
    }

    uint256 private _dealIdCounter;

    IPlayerRegistry public playerRegistry;
    IAddressRegistry public addressRegistry;
    mapping(uint8 => uint256) public timers;
    // 0=consent 1=medical 2=hijack 3=dispute 4=renego 5=funding 6=mutualCancel

    mapping(uint256 => Deal)                                private _deals;
    mapping(uint256 => TransferTypes.AddOn[])               private _dealAddOns;
    mapping(uint256 => HijackBid)                           private _hijackBids;
    mapping(uint256 => uint256)                             private _playerDeal;
    mapping(address => mapping(address => uint256))         private _claimable;
    mapping(uint256 => mapping(address => uint256))         private _addOnDeposits;
    mapping(address => bool)                                private _approvedTokens;
    // installmentSchedule[dealId][index] = Installment
    mapping(uint256 => mapping(uint8 => TransferTypes.Installment)) private _installments;

    event DealCreated(uint256 indexed dealId, uint256 indexed playerId, address indexed buyingClub);
    event PlayerConsentRequested(uint256 indexed dealId, uint256 indexed playerId, address buyingClub);
    event PlayerConsented(uint256 indexed dealId, uint256 indexed playerId);
    event PlayerDeclined(uint256 indexed dealId, uint256 indexed playerId);
    event MedicalSubmitted(uint256 indexed dealId, TransferTypes.MedicalOutcome outcome);
    event MedicalRenegotiationStarted(uint256 indexed dealId);
    event MedicalRenegotiationResolved(uint256 indexed dealId, uint256 newFee);
    event MedicalDisputeEscalated(uint256 indexed dealId, address indexed escalatedBy);
    event MedicalDisputeResolved(uint256 indexed dealId);
    event HijackBidSubmitted(uint256 indexed dealId, address indexed hijackClub, uint256 transferFee);
    event HijackBidAccepted(uint256 indexed dealId, address indexed hijackClub);
    event HijackBidRejected(uint256 indexed dealId, address indexed hijackClub);
    event MutualCancelProposed(uint256 indexed dealId, address indexed proposer);
    event MutualCancelConfirmed(uint256 indexed dealId);
    event FundingReceived(uint256 indexed dealId, address indexed buyingClub, uint256 amount);
    event DealCompleted(uint256 indexed dealId, uint256 indexed playerId, address indexed newClub);
    event DealCancelled(uint256 indexed dealId, TransferTypes.CancelReason reason);
    event DealFrozen(uint256 indexed dealId);
    event DealUnfrozen(uint256 indexed dealId);
    event DisputeRaised(uint256 indexed dealId, address indexed raisedBy);
    event DisputeResolved(uint256 indexed dealId);
    event AddOnTriggered(uint256 indexed dealId, uint256 indexed idx, uint256 amount, address recipient);
    event SigningBonusClaimed(uint256 indexed dealId, address indexed wallet, uint256 amount);
    event FundsClaimed(address indexed recipient, address indexed token, uint256 amount);

    error ReentrantCall();
    error InvalidAddress();
    error NothingToWithdraw();
    error InsufficientProtocolBalance(uint256 requested, uint256 available);
    error InvalidAmount();
    error TokenNotApproved();
    error DealNotFound();
    error WrongDealState();
    error NotSellingClub();
    error NotBuyingClub();
    error NotPlayerWallet();
    error PlayerWalletNotSet();
    error DealIsFrozen();
    error DealNotFrozen();
    error ConsentWindowExpired();
    error MedicalWindowExpired();
    error FundingWindowExpired();
    error DisputeWindowExpired();
    error MedicalAlreadySubmitted();
    error HijackWindowClosed();
    error NothingToClaim();
    error NoSigningBonus();
    error SigningBonusAlreadyClaimed();
    error AddOnNotFound();
    error AddOnAlreadyTriggered();
    error TransferWindowClosed();
    error LeagueDisputeDeadlineExpired();
    error MutualCancelAlreadyProposed();
    error MutualCancelNotProposed();
    error MutualCancelExpiredError();
    error CannotConfirmOwnProposal();
    error TimerTooShort();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(
        address _playerRegistry,
        address _addressRegistry,
        address _treasury,
        address _admin
    ) external initializer {
        if (_playerRegistry == address(0)) revert InvalidAddress();
        if (_addressRegistry == address(0)) revert InvalidAddress();
        if (_treasury        == address(0)) revert InvalidAddress();
        if (_admin           == address(0)) revert InvalidAddress();
        __AccessControl_init();
        __Pausable_init();
        _reentrancyStatus = _NOT_ENTERED;
        playerRegistry    = IPlayerRegistry(_playerRegistry);
        addressRegistry   = IAddressRegistry(_addressRegistry);
        treasury          = _treasury;
        timers[0] = 72 hours;
        timers[1] = 72 hours;
        timers[2] = 48 hours;
        timers[3] = 72 hours;
        timers[4] = 48 hours;
        timers[5] = 48 hours;
        timers[6] = 48 hours;
        protocolFeeBps    = 50;
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE,         _admin);
        _grantRole(LEAGUE_ROLE,        _admin);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    modifier dealExists(uint256 dealId) {
        if (_deals[dealId].playerId == 0) revert DealNotFound();
        _;
    }
    modifier notFrozen(uint256 dealId) {
        if (_deals[dealId].frozen) revert DealIsFrozen();
        _;
    }
    modifier onlyApprovedToken(address token) {
        if (!_approvedTokens[token]) revert TokenNotApproved();
        _;
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function setProtocolFee(uint256 bps) external onlyRole(ADMIN_ROLE) {
        _setProtocolFee(bps);
    }

    function scheduleProtocolTreasuryUpdate(address newTreasury) external onlyRole(ADMIN_ROLE) {
        if (newTreasury == address(0)) revert InvalidAddress();
        _scheduleProtocolTreasuryUpdate(newTreasury);
    }

    function executeProtocolTreasuryUpdate() external onlyRole(ADMIN_ROLE) {
        _executeProtocolTreasuryUpdate();
    }

    function withdrawFees(address token, uint256 amount) external onlyRole(ADMIN_ROLE) nonReentrant {
        if (amount == 0) revert NothingToWithdraw();
        if (treasury == address(0)) revert InvalidAddress();
        uint256 avail = _claimable[treasury][token];
        if (amount > avail) revert InsufficientProtocolBalance(amount, avail);
        _claimable[treasury][token] = avail - amount;
        IERC20(token).safeTransfer(treasury, amount);
        emit ProtocolFeesWithdrawn(treasury, token, amount);
    }

    // which: 0=consent 1=medical 2=hijack 3=dispute 4=renego 5=funding 6=mutualCancel
    function setTimer(uint8 which, uint256 d) external onlyRole(ADMIN_ROLE) {
        if (d < MIN_TIMER) revert TimerTooShort();
        if (which > 6) revert InvalidAmount();
        timers[which] = d;
    }

    function approveToken(address token) external onlyRole(ADMIN_ROLE) {
        if (token == address(0)) revert InvalidAddress();
        _approvedTokens[token] = true;
    }

    function revokeToken(address token) external onlyRole(ADMIN_ROLE) {
        _approvedTokens[token] = false;
    }

    function pause()   external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    // ─── Initialisation (TransferEscrow only) ─────────────────────────────────

    function initializeDeal(
        TransferTypes.DealInitParams calldata p,
        TransferTypes.AddOn[]        calldata addOns
    )
        external
        onlyRole(TRANSFER_ESCROW_ROLE)
        returns (uint256 dealId)
    {
        _dealIdCounter++;
        dealId = _dealIdCounter;

        uint256 instCount = FeeLib.validateInstallments(
            p.installmentAmounts, p.installmentDueDates, p.transferFee
        );

        _deals[dealId] = Deal({
            offerId:                   p.offerId,
            playerId:                  p.playerId,
            sellingClub:               p.sellingClub,
            buyingClub:                p.buyingClub,
            paymentToken:              p.paymentToken,
            transferFee:               p.transferFee,
            sellOnBps:                 p.sellOnBps,
            sellOnRecipient:           p.sellOnRecipient,
            sellerAgentBps:            p.sellerAgentBps,
            sellerAgent:               p.sellerAgent,
            buyerAgentBps:             p.buyerAgentBps,
            buyerAgent:                p.buyerAgent,
            signingBonusMonths:     p.signingBonusMonths,
            signingBonusAmount:     p.signingBonusAmount,
            signingBonusClaimed:    false,
            signingBonusExpiry:     0,
            minimumHijackIncrementBps: p.minimumHijackIncrementBps,
            state:                     TransferTypes.DealState.AWAITING_PLAYER_CONSENT,
            stateDeadline:             block.timestamp + p.consentWindowDuration,
            acceptedAt:                block.timestamp,
            fundedAt:                  0,
            medicalHash:               bytes32(0),
            medicalOutcome:            TransferTypes.MedicalOutcome.NONE,
            frozen:                    false,
            frozenAt:                  0,
            hijackDeposit:             0,
            hijackDepositClub:         address(0),
            mutualCancelProposer:      address(0),
            mutualCancelDeadline:      0,
            installmentCount:          uint8(instCount),
            installmentsPaid:          0
        });

        // I store the installment schedule
        for (uint256 i = 0; i < instCount; i++) {
            _installments[dealId][uint8(i)] = TransferTypes.Installment({
                amount:  p.installmentAmounts[i],
                dueDate: p.installmentDueDates[i],
                paid:    false
            });
        }

        for (uint256 i = 0; i < addOns.length; i++) {
            _dealAddOns[dealId].push(addOns[i]);
        }

        _playerDeal[p.playerId] = dealId;
        emit DealCreated(dealId, p.playerId, p.buyingClub);
        emit PlayerConsentRequested(dealId, p.playerId, p.buyingClub);
    }

    function receiveHijackBid(
        uint256 dealId,
        address buyingClub,
        uint256 transferFee,
        uint256 buyerAgentBps,
        address buyerAgent,
        uint256 signingBonusMonths
    )
        external
        onlyRole(TRANSFER_ESCROW_ROLE)
        dealExists(dealId)
    {
        Deal storage deal = _deals[dealId];
        // I re-check state here because TransferEscrow already pulled funds — if state
        // changed between getDealView and this call, revert before touching storage
        if (deal.state != TransferTypes.DealState.HIJACK_WINDOW) revert WrongDealState();
        if (block.timestamp > deal.stateDeadline)                revert WrongDealState();

        HijackBid storage existing = _hijackBids[dealId];
        if (existing.exists) {
            _claimable[existing.buyingClub][deal.paymentToken] += existing.transferFee;
        }

        _hijackBids[dealId] = HijackBid({
            buyingClub:            buyingClub,
            transferFee:           transferFee,
            buyerAgentBps:         buyerAgentBps,
            buyerAgent:            buyerAgent,
            signingBonusMonths: signingBonusMonths,
            depositedAt:           block.timestamp,
            exists:                true
        });

        emit HijackBidSubmitted(dealId, buyingClub, transferFee);
    }

    // ─── League ───────────────────────────────────────────────────────────────

    function freezeDeal(uint256 dealId) external onlyRole(LEAGUE_ROLE) dealExists(dealId) {
        Deal storage deal = _deals[dealId];
        if (deal.frozen) revert DealIsFrozen();
        if (deal.state == TransferTypes.DealState.COMPLETED ||
            deal.state == TransferTypes.DealState.CANCELLED) revert WrongDealState();
        deal.frozen   = true;
        deal.frozenAt = block.timestamp;
        emit DealFrozen(dealId);
    }

    function unfreezeDeal(uint256 dealId) external onlyRole(LEAGUE_ROLE) dealExists(dealId) {
        Deal storage deal = _deals[dealId];
        if (!deal.frozen) revert DealNotFrozen();
        uint256 frozenFor = block.timestamp - deal.frozenAt;
        if (deal.stateDeadline > 0) deal.stateDeadline += frozenFor;
        deal.frozen   = false;
        deal.frozenAt = 0;
        emit DealUnfrozen(dealId);
    }

    function forceCancelDeal(uint256 dealId)
        external onlyRole(LEAGUE_ROLE) nonReentrant dealExists(dealId)
    {
        Deal storage deal = _deals[dealId];
        if (deal.state == TransferTypes.DealState.COMPLETED ||
            deal.state == TransferTypes.DealState.CANCELLED) revert WrongDealState();
        _cancelDeal(dealId, TransferTypes.CancelReason.FORCE_CANCELLED);
    }

    function forceComplete(uint256 dealId)
        external onlyRole(LEAGUE_ROLE) nonReentrant dealExists(dealId)
    {
        Deal storage deal = _deals[dealId];
        if (deal.state != TransferTypes.DealState.FUNDED &&
            deal.state != TransferTypes.DealState.DISPUTE_WINDOW) revert WrongDealState();
        _settleDeal(dealId);
    }

    function resolveDispute(uint256 dealId)
        external onlyRole(LEAGUE_ROLE) nonReentrant dealExists(dealId)
    {
        Deal storage deal = _deals[dealId];
        if (deal.state != TransferTypes.DealState.DISPUTE_WINDOW) revert WrongDealState();
        emit DisputeResolved(dealId);
        _settleDeal(dealId);
    }

    function triggerAddOn(uint256 dealId, uint256 idx)
        external onlyRole(LEAGUE_ROLE) nonReentrant dealExists(dealId)
    {
        Deal storage deal = _deals[dealId];
        if (deal.state != TransferTypes.DealState.COMPLETED) revert WrongDealState();
        TransferTypes.AddOn[] storage addOns = _dealAddOns[dealId];
        if (idx >= addOns.length)   revert AddOnNotFound();
        TransferTypes.AddOn storage addOn = addOns[idx];
        if (addOn.triggered)        revert AddOnAlreadyTriggered();
        addOn.triggered = true;
        address recipient;
        if (addOn.toPlayer) {
            IPlayerRegistry.Player memory player = playerRegistry.getPlayer(deal.playerId);
            if (player.playerWallet == address(0)) revert PlayerWalletNotSet();
            recipient = player.playerWallet;
        } else {
            recipient = deal.sellingClub;
        }
        uint256 available = _addOnDeposits[dealId][deal.paymentToken];
        if (available < addOn.amount) revert InvalidAmount();
        _addOnDeposits[dealId][deal.paymentToken] -= addOn.amount;
        _claimable[recipient][deal.paymentToken]  += addOn.amount;
        emit AddOnTriggered(dealId, idx, addOn.amount, recipient);
    }

    // ─── Selling Club ─────────────────────────────────────────────────────────

    function acceptHijackBid(uint256 dealId)
        external whenNotPaused nonReentrant dealExists(dealId) notFrozen(dealId)
    {
        Deal storage deal = _deals[dealId];
        if (deal.sellingClub != msg.sender)                       revert NotSellingClub();
        if (deal.state != TransferTypes.DealState.HIJACK_WINDOW) revert WrongDealState();
        HijackBid storage hijack = _hijackBids[dealId];
        if (!hijack.exists) revert WrongDealState();

        IPlayerRegistry.Player memory player = playerRegistry.getPlayer(deal.playerId);
        uint256 newSigningBonus = 0;
        if (hijack.signingBonusMonths > 0 && player.weeklySalary > 0) {
            newSigningBonus = player.weeklySalary * 4 * hijack.signingBonusMonths;
        }

        deal.buyingClub             = hijack.buyingClub;
        deal.transferFee            = hijack.transferFee;
        deal.buyerAgentBps          = hijack.buyerAgentBps;
        deal.buyerAgent             = hijack.buyerAgent;
        deal.signingBonusMonths  = hijack.signingBonusMonths;
        deal.signingBonusAmount  = newSigningBonus;
        deal.signingBonusClaimed = false;
        deal.state                  = TransferTypes.DealState.AWAITING_HIJACK_CONSENT;
        deal.stateDeadline          = block.timestamp + timers[0];
        deal.medicalHash            = bytes32(0);
        deal.medicalOutcome         = TransferTypes.MedicalOutcome.NONE;
        deal.hijackDeposit          = hijack.transferFee;
        deal.hijackDepositClub      = hijack.buyingClub;
        hijack.exists               = false;

        emit HijackBidAccepted(dealId, deal.buyingClub);
        emit PlayerConsentRequested(dealId, deal.playerId, deal.buyingClub);
    }

    function rejectHijackBid(uint256 dealId)
        external whenNotPaused nonReentrant dealExists(dealId) notFrozen(dealId)
    {
        Deal storage deal = _deals[dealId];
        if (deal.sellingClub != msg.sender)                       revert NotSellingClub();
        if (deal.state != TransferTypes.DealState.HIJACK_WINDOW) revert WrongDealState();
        HijackBid storage hijack = _hijackBids[dealId];
        if (!hijack.exists) revert WrongDealState();
        _claimable[hijack.buyingClub][deal.paymentToken] += hijack.transferFee;
        hijack.exists = false;
        emit HijackBidRejected(dealId, hijack.buyingClub);
    }

    function acceptMedicalRenegotiation(uint256 dealId, uint256 newFee)
        external whenNotPaused dealExists(dealId) notFrozen(dealId)
    {
        Deal storage deal = _deals[dealId];
        if (deal.sellingClub != msg.sender)                             revert NotSellingClub();
        if (deal.state != TransferTypes.DealState.MEDICAL_RENEGOTIATION) revert WrongDealState();
        if (block.timestamp > deal.stateDeadline)                       revert MedicalWindowExpired();
        if (newFee == 0 || newFee > MAX_PRICE)                          revert InvalidAmount();
        if (newFee < deal.transferFee) {
            _claimable[deal.buyingClub][deal.paymentToken] += deal.transferFee - newFee;
        }
        deal.transferFee   = newFee;
        deal.state         = TransferTypes.DealState.HIJACK_WINDOW;
        deal.stateDeadline = block.timestamp + timers[2];
        emit MedicalRenegotiationResolved(dealId, newFee);
    }

    function rejectMedicalRenegotiation(uint256 dealId)
        external whenNotPaused nonReentrant dealExists(dealId) notFrozen(dealId)
    {
        Deal storage deal = _deals[dealId];
        if (deal.sellingClub != msg.sender)                             revert NotSellingClub();
        if (deal.state != TransferTypes.DealState.MEDICAL_RENEGOTIATION) revert WrongDealState();
        _cancelDeal(dealId, TransferTypes.CancelReason.MEDICAL_RENEGO_REJECTED);
    }

    function escalateToLeague(uint256 dealId)
        external whenNotPaused nonReentrant dealExists(dealId) notFrozen(dealId)
    {
        Deal storage deal = _deals[dealId];
        if (deal.state != TransferTypes.DealState.MEDICAL_RENEGOTIATION) revert WrongDealState();
        if (msg.sender != deal.sellingClub && msg.sender != deal.buyingClub) revert WrongDealState();
        bool windowExpired = block.timestamp > deal.stateDeadline;
        if (!windowExpired) {
            if (block.timestamp < (deal.stateDeadline - timers[4] / 2)) revert WrongDealState();
        }
        deal.state         = TransferTypes.DealState.MEDICAL_DISPUTE;
        deal.stateDeadline = block.timestamp + LEAGUE_DISPUTE_DEADLINE;
        emit MedicalDisputeEscalated(dealId, msg.sender);
    }

    // ─── Buying Club ──────────────────────────────────────────────────────────

    function fundDeal(uint256 dealId)
        external whenNotPaused nonReentrant dealExists(dealId) notFrozen(dealId)
    {
        Deal storage deal = _deals[dealId];
        if (deal.state != TransferTypes.DealState.FUNDING_PENDING) revert WrongDealState();
        if (deal.buyingClub != msg.sender)                          revert NotBuyingClub();
        if (block.timestamp > deal.stateDeadline)                   revert FundingWindowExpired();
        if (!ITransferWindow(addressRegistry.get(RegistryKeys.TRANSFER_WINDOW)).isWindowOpen())                         revert TransferWindowClosed();

        // I only require installment #0 + salary guarantee at funding — real-world practice
        uint256 firstInstallment = _installments[dealId][0].amount;
        uint256 totalRequired    = firstInstallment + deal.signingBonusAmount;
        uint256 alreadyHeld      = 0;
        if (deal.hijackDepositClub == msg.sender && deal.hijackDeposit > 0) {
            alreadyHeld            = deal.hijackDeposit > firstInstallment ? firstInstallment : deal.hijackDeposit;
            deal.hijackDeposit    -= alreadyHeld;
            if (deal.hijackDeposit == 0) deal.hijackDepositClub = address(0);
        }
        if (totalRequired > alreadyHeld) {
            IERC20(deal.paymentToken).safeTransferFrom(
                msg.sender, address(this), totalRequired - alreadyHeld
            );
        }
        _installments[dealId][0].paid = true;
        deal.state         = TransferTypes.DealState.FUNDED;
        deal.fundedAt      = block.timestamp;
        deal.stateDeadline = block.timestamp + timers[3];
        emit FundingReceived(dealId, msg.sender, totalRequired);
    }

    function getInstallment(uint256 dealId, uint8 index)
        external view returns (TransferTypes.Installment memory)
    {
        return _installments[dealId][index];
    }


    function raiseDispute(uint256 dealId)
        external dealExists(dealId) notFrozen(dealId)
    {
        Deal storage deal = _deals[dealId];
        if (deal.state != TransferTypes.DealState.FUNDED) revert WrongDealState();
        // I use stateDeadline not fundedAt so freeze extensions are honoured
        if (block.timestamp >= deal.stateDeadline) revert DisputeWindowExpired();
        if (msg.sender != deal.buyingClub && msg.sender != deal.sellingClub) revert WrongDealState();
        deal.state = TransferTypes.DealState.DISPUTE_WINDOW;
        emit DisputeRaised(dealId, msg.sender);
    }

    function proposeMutualCancel(uint256 dealId)
        external whenNotPaused dealExists(dealId) notFrozen(dealId)
    {
        Deal storage deal = _deals[dealId];
        if (deal.state == TransferTypes.DealState.COMPLETED    ||
            deal.state == TransferTypes.DealState.CANCELLED    ||
            deal.state == TransferTypes.DealState.FUNDED       ||
            deal.state == TransferTypes.DealState.DISPUTE_WINDOW) revert WrongDealState();
        if (msg.sender != deal.buyingClub && msg.sender != deal.sellingClub) revert WrongDealState();
        if (deal.mutualCancelProposer != address(0)) revert MutualCancelAlreadyProposed();
        deal.mutualCancelProposer = msg.sender;
        deal.mutualCancelDeadline = block.timestamp + timers[6];
        emit MutualCancelProposed(dealId, msg.sender);
    }

    function confirmMutualCancel(uint256 dealId)
        external whenNotPaused nonReentrant dealExists(dealId) notFrozen(dealId)
    {
        Deal storage deal = _deals[dealId];
        if (deal.mutualCancelProposer == address(0))     revert MutualCancelNotProposed();
        if (block.timestamp > deal.mutualCancelDeadline) revert MutualCancelExpiredError();
        if (msg.sender == deal.mutualCancelProposer)     revert CannotConfirmOwnProposal();
        if (msg.sender != deal.buyingClub && msg.sender != deal.sellingClub) revert WrongDealState();
        emit MutualCancelConfirmed(dealId);
        _cancelDeal(dealId, TransferTypes.CancelReason.MUTUAL_CANCEL_AGREED);
    }

    function depositAddOnFunds(uint256 dealId, uint256 amount)
        external nonReentrant dealExists(dealId)
    {
        Deal storage deal = _deals[dealId];
        if (deal.state != TransferTypes.DealState.COMPLETED) revert WrongDealState();
        if (deal.buyingClub != msg.sender)                   revert NotBuyingClub();
        if (amount == 0)                                     revert InvalidAmount();
        IERC20(deal.paymentToken).safeTransferFrom(msg.sender, address(this), amount);
        _addOnDeposits[dealId][deal.paymentToken] += amount;
    }

    function withdrawClaimable(address token)
        external nonReentrant
    {
        uint256 amount = _claimable[msg.sender][token];
        if (amount == 0) revert NothingToClaim();
        _claimable[msg.sender][token] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit FundsClaimed(msg.sender, token, amount);
    }

    // ─── Player ───────────────────────────────────────────────────────────────

    function consentToTransfer(uint256 dealId)
        external whenNotPaused dealExists(dealId) notFrozen(dealId)
    {
        Deal storage deal = _deals[dealId];
        bool isStandard = deal.state == TransferTypes.DealState.AWAITING_PLAYER_CONSENT;
        bool isHijack   = deal.state == TransferTypes.DealState.AWAITING_HIJACK_CONSENT;
        if (!isStandard && !isHijack)             revert WrongDealState();
        if (block.timestamp > deal.stateDeadline) revert ConsentWindowExpired();
        IPlayerRegistry.Player memory player = playerRegistry.getPlayer(deal.playerId);
        if (player.playerWallet == address(0)) revert PlayerWalletNotSet();
        if (player.playerWallet != msg.sender) revert NotPlayerWallet();
        deal.state         = isHijack
            ? TransferTypes.DealState.AWAITING_HIJACK_MEDICAL
            : TransferTypes.DealState.AWAITING_TRANSFER_MEDICAL;
        deal.stateDeadline  = block.timestamp + timers[1];
        deal.medicalHash    = bytes32(0);
        deal.medicalOutcome = TransferTypes.MedicalOutcome.NONE;
        emit PlayerConsented(dealId, deal.playerId);
    }

    function declineTransfer(uint256 dealId)
        external whenNotPaused nonReentrant dealExists(dealId) notFrozen(dealId)
    {
        Deal storage deal = _deals[dealId];
        bool isHijack = deal.state == TransferTypes.DealState.AWAITING_HIJACK_CONSENT;
        if (deal.state != TransferTypes.DealState.AWAITING_PLAYER_CONSENT && !isHijack)
            revert WrongDealState();
        IPlayerRegistry.Player memory player = playerRegistry.getPlayer(deal.playerId);
        if (player.playerWallet == address(0)) revert PlayerWalletNotSet();
        if (player.playerWallet != msg.sender) revert NotPlayerWallet();
        emit PlayerDeclined(dealId, deal.playerId);
        if (isHijack && deal.hijackDeposit > 0) {
            _claimable[deal.hijackDepositClub][deal.paymentToken] += deal.hijackDeposit;
            deal.hijackDeposit     = 0;
            deal.hijackDepositClub = address(0);
        }
        _cancelDeal(dealId, TransferTypes.CancelReason.PLAYER_DECLINED);
    }

    function submitMedical(
        uint256 dealId,
        TransferTypes.MedicalOutcome outcome,
        bytes32 medicalHash
    )
        external whenNotPaused dealExists(dealId) notFrozen(dealId)
    {
        Deal storage deal = _deals[dealId];
        bool isStandard = deal.state == TransferTypes.DealState.AWAITING_TRANSFER_MEDICAL;
        bool isHijack   = deal.state == TransferTypes.DealState.AWAITING_HIJACK_MEDICAL;
        if (!isStandard && !isHijack)             revert WrongDealState();
        if (deal.buyingClub != msg.sender)         revert NotBuyingClub();
        if (block.timestamp > deal.stateDeadline) revert MedicalWindowExpired();
        if (deal.medicalHash != bytes32(0))        revert MedicalAlreadySubmitted();
        if (medicalHash == bytes32(0))             revert InvalidAddress();
        if (outcome == TransferTypes.MedicalOutcome.NONE) revert InvalidAmount();
        deal.medicalHash    = medicalHash;
        deal.medicalOutcome = outcome;
        emit MedicalSubmitted(dealId, outcome);

        if (outcome == TransferTypes.MedicalOutcome.PASSED) {
            if (isHijack) {
                deal.state         = TransferTypes.DealState.FUNDING_PENDING;
                deal.stateDeadline = block.timestamp + timers[5];
            } else {
                deal.state         = TransferTypes.DealState.HIJACK_WINDOW;
                deal.stateDeadline = block.timestamp + timers[2];
            }
        } else if (outcome == TransferTypes.MedicalOutcome.FAILED) {
            if (isHijack && deal.hijackDeposit > 0) {
                uint256 penalty = (deal.hijackDeposit * HIJACK_FAIL_PENALTY_BPS) / BPS_DENOMINATOR;
                _claimable[deal.buyingClub][deal.paymentToken]  += deal.hijackDeposit - penalty;
                _claimable[deal.sellingClub][deal.paymentToken] += penalty;
                deal.hijackDeposit     = 0;
                deal.hijackDepositClub = address(0);
            }
            _cancelDeal(dealId, TransferTypes.CancelReason.MEDICAL_FAILED);
        } else {
            deal.state         = TransferTypes.DealState.MEDICAL_RENEGOTIATION;
            deal.stateDeadline = block.timestamp + timers[4];
            emit MedicalRenegotiationStarted(dealId);
        }
    }


    function claimSigningBonus(uint256 dealId)
        external nonReentrant dealExists(dealId)
    {
        Deal storage deal = _deals[dealId];
        if (deal.state != TransferTypes.DealState.COMPLETED) revert WrongDealState();
        if (deal.signingBonusAmount == 0)                 revert NoSigningBonus();
        if (deal.signingBonusClaimed)                     revert SigningBonusAlreadyClaimed();
        IPlayerRegistry.Player memory player = playerRegistry.getPlayer(deal.playerId);
        if (player.playerWallet == address(0)) revert PlayerWalletNotSet();
        if (player.playerWallet != msg.sender) revert NotPlayerWallet();
        deal.signingBonusClaimed = true;
        _claimable[msg.sender][deal.paymentToken] += deal.signingBonusAmount;
        emit SigningBonusClaimed(dealId, msg.sender, deal.signingBonusAmount);
    }

    // ─── External Callbacks (TRANSFER_ESCROW_ROLE only) ───────────────────────
    // processExpiry, expireMutualCancel, resolveDeadlock, walkAwayFromRenegotiation
    // live in TransferEscrow and call back here to mutate state.

    function extCancel(uint256 dealId, uint8 reason)
        external onlyRole(TRANSFER_ESCROW_ROLE) nonReentrant dealExists(dealId)
    {
        _cancelDeal(dealId, TransferTypes.CancelReason(reason));
    }

    function extHijackStallAndCancel(uint256 dealId)
        external onlyRole(TRANSFER_ESCROW_ROLE) nonReentrant dealExists(dealId)
    {
        Deal storage deal = _deals[dealId];
        if (deal.hijackDeposit > 0) {
            uint256 penalty = (deal.hijackDeposit * HIJACK_STALL_PENALTY_BPS) / BPS_DENOMINATOR;
            _claimable[deal.hijackDepositClub][deal.paymentToken] += deal.hijackDeposit - penalty;
            _claimable[deal.sellingClub][deal.paymentToken]       += penalty;
            deal.hijackDeposit     = 0;
            deal.hijackDepositClub = address(0);
        }
        _cancelDeal(dealId, TransferTypes.CancelReason.HIJACK_MEDICAL_STALL);
    }

    function extAdvanceToFunding(uint256 dealId)
        external onlyRole(TRANSFER_ESCROW_ROLE) dealExists(dealId)
    {
        Deal storage deal  = _deals[dealId];
        deal.state         = TransferTypes.DealState.FUNDING_PENDING;
        deal.stateDeadline = block.timestamp + timers[5];
    }

    // op 1 = advance to hijack (original fee), op 2 = set newFee and advance to hijack
    function extAdvanceToHijack(uint256 dealId, uint256 newFee)
        external onlyRole(TRANSFER_ESCROW_ROLE) nonReentrant dealExists(dealId)
    {
        Deal storage deal = _deals[dealId];
        if (newFee > 0) {
            if (newFee > MAX_PRICE) revert InvalidAmount();
            if (newFee < deal.transferFee) {
                _claimable[deal.buyingClub][deal.paymentToken] += deal.transferFee - newFee;
            }
            deal.transferFee = newFee;
        }
        deal.state         = TransferTypes.DealState.HIJACK_WINDOW;
        deal.stateDeadline = block.timestamp + timers[2];
        emit MedicalDisputeResolved(dealId);
    }

    function extWalkAwayPenalty(uint256 dealId)
        external onlyRole(TRANSFER_ESCROW_ROLE) nonReentrant dealExists(dealId)
    {
        // I cancel cleanly — at MEDICAL_RENEGOTIATION no funds are locked yet
        // so crediting claimable would create phantom balances
        _cancelDeal(dealId, TransferTypes.CancelReason.BUYER_WALKED_AWAY);
    }

    function extClearMutualCancel(uint256 dealId)
        external onlyRole(TRANSFER_ESCROW_ROLE) dealExists(dealId)
    {
        Deal storage deal         = _deals[dealId];
        deal.mutualCancelProposer = address(0);
        deal.mutualCancelDeadline = 0;
    }

    // I expose settlement to TransferEscrow so processExpiry can auto-complete
    // FUNDED deals once the dispute window expires with no dispute raised
    function extSettle(uint256 dealId)
        external onlyRole(TRANSFER_ESCROW_ROLE) nonReentrant dealExists(dealId)
    {
        // I skip the state check here — processExpiry in TransferEscrow already
        // validated state before calling, saving bytecode within the 24KB limit
        _settleDeal(dealId);
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _settleDeal(uint256 dealId) internal {
        Deal storage deal = _deals[dealId];
        deal.state             = TransferTypes.DealState.COMPLETED;
        deal.signingBonusExpiry   = block.timestamp + 90 days;
        _playerDeal[deal.playerId] = 0;

        // I only settle installment #0 here — subsequent installments paid via payInstallment
        uint256 fee = _installments[dealId][0].amount;
        (
            uint256 protocolAmt,
            uint256 sellOnAmt,
            uint256 sellerAgentAmt,
            uint256 buyerAgentAmt,
            uint256 sellerAmt
        ) = FeeLib.computeFees(
            fee,
            (protocolFeeBps > 0 && treasury != address(0)) ? protocolFeeBps : 0,
            (deal.sellOnBps > 0 && deal.sellOnRecipient != address(0)) ? deal.sellOnBps : 0,
            (deal.sellerAgentBps > 0 && deal.sellerAgent != address(0)) ? deal.sellerAgentBps : 0,
            (deal.buyerAgentBps  > 0 && deal.buyerAgent  != address(0)) ? deal.buyerAgentBps  : 0
        );

        if (protocolAmt    > 0) _claimable[treasury][deal.paymentToken]             += protocolAmt;
        if (sellOnAmt      > 0) _claimable[deal.sellOnRecipient][deal.paymentToken]  += sellOnAmt;
        if (sellerAgentAmt > 0) _claimable[deal.sellerAgent][deal.paymentToken]      += sellerAgentAmt;
        if (buyerAgentAmt  > 0) _claimable[deal.buyerAgent][deal.paymentToken]       += buyerAgentAmt;
        _claimable[deal.sellingClub][deal.paymentToken] += sellerAmt;

        playerRegistry.escrowTransfer(deal.playerId, deal.sellingClub, deal.buyingClub);
        emit DealCompleted(dealId, deal.playerId, deal.buyingClub);
    }

    function _cancelDeal(uint256 dealId, TransferTypes.CancelReason reason) internal {
        Deal storage deal   = _deals[dealId];
        TransferTypes.DealState prevState = deal.state;
        deal.state             = TransferTypes.DealState.CANCELLED;
        _playerDeal[deal.playerId] = 0;

        if (prevState == TransferTypes.DealState.FUNDED ||
            prevState == TransferTypes.DealState.DISPUTE_WINDOW) {
            // I refund installment #0 only — that is what was actually deposited
            _claimable[deal.buyingClub][deal.paymentToken] +=
                _installments[dealId][0].amount + deal.signingBonusAmount;
        }

        HijackBid storage hijack = _hijackBids[dealId];
        if (hijack.exists) {
            _claimable[hijack.buyingClub][deal.paymentToken] += hijack.transferFee;
            hijack.exists = false;
        }

        if (deal.hijackDeposit > 0 && deal.hijackDepositClub != address(0)) {
            if (prevState != TransferTypes.DealState.FUNDED &&
                prevState != TransferTypes.DealState.DISPUTE_WINDOW) {
                _claimable[deal.hijackDepositClub][deal.paymentToken] += deal.hijackDeposit;
            }
            deal.hijackDeposit     = 0;
            deal.hijackDepositClub = address(0);
        }

        emit DealCancelled(dealId, reason);
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    function getDealView(uint256 dealId)
        external view returns (IDealEscrow.DealView memory v)
    {
        Deal storage deal = _deals[dealId];
        if (deal.playerId == 0) return v;
        v.exists                    = true;
        v.sellingClub               = deal.sellingClub;
        v.buyingClub                = deal.buyingClub;
        v.paymentToken              = deal.paymentToken;
        v.transferFee               = deal.transferFee;
        v.minimumHijackIncrementBps = deal.minimumHijackIncrementBps;
        v.state                     = IDealEscrow.DealState(uint8(deal.state));
        v.stateDeadline             = deal.stateDeadline;
    }

    function getExpiryView(uint256 dealId) external view returns (
        bool    exists,
        bool    frozen,
        uint8   state,
        uint256 stateDeadline,
        uint256 mutualCancelDeadline,
        address mutualCancelProposer
    ) {
        Deal storage deal = _deals[dealId];
        if (deal.playerId == 0) return (false, false, 0, 0, 0, address(0));
        return (
            true,
            deal.frozen,
            uint8(deal.state),
            deal.stateDeadline,
            deal.mutualCancelDeadline,
            deal.mutualCancelProposer
        );
    }

    function getPlayerDeal(uint256 playerId) external view returns (uint256) {
        return _playerDeal[playerId];
    }

    function getClaimable(address account, address token) external view returns (uint256) {
        return _claimable[account][token];
    }

    function getAddOnDeposit(uint256 dealId, address token) external view returns (uint256) {
        return _addOnDeposits[dealId][token];
    }

    function totalDeals() external view returns (uint256) {
        return _dealIdCounter;
    }
}
