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

interface ICompetingBidManager {
    function hasActiveBid(uint256 dealId) external view returns (bool);
}

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
    bytes32 public constant TRANSFER_ESCROW_ROLE      = keccak256("TRANSFER_ESCROW_ROLE");
    bytes32 public constant COMPETING_BID_MANAGER_ROLE = keccak256("COMPETING_BID_MANAGER_ROLE");

    address public competingBidManager;

    uint256 internal constant MAX_PRICE                = 500_000_000 ether;
    uint256 internal constant BPS_DENOMINATOR          = 10_000;
    uint256 internal constant LEAGUE_DISPUTE_DEADLINE  = 7 days;
    uint256 internal constant MIN_TIMER = 10 seconds;

    struct Deal {
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
        uint256  signingBonusAmount;
        bool     signingBonusClaimed;
        uint256  signingBonusExpiry;
        TransferTypes.DealState state;
        uint256  stateDeadline;
        bytes32  medicalHash;
        bool     frozen;
        uint256  frozenAt;
        address  originalBuyer;      // Club B — preserved when Club C takes over
        address  mutualCancelProposer;
        uint256  mutualCancelDeadline;
    }


    uint256 private _dealIdCounter;

    IPlayerRegistry public playerRegistry;
    IAddressRegistry public addressRegistry;
    mapping(uint8 => uint256) public timers;
    // 0=consent 1=medical 2=unused(was hijack) 3=dispute 4=renego 5=funding 6=mutualCancel

    mapping(uint256 => Deal)                                private _deals;
    mapping(uint256 => TransferTypes.AddOn[])               private _dealAddOns;
    mapping(uint256 => uint256)                             private _playerDeal;
    mapping(address => mapping(address => uint256))         private _claimable;
    mapping(uint256 => mapping(address => uint256))         private _addOnDeposits;
    mapping(address => bool)                                private _approvedTokens;
    // installmentSchedule[dealId][index] = Installment
    mapping(uint256 => mapping(uint8 => TransferTypes.Installment)) private _installments;

    // ─── Storage gap ──────────────────────────────────────────────────────────
    // I reserve 50 slots for future upgrades — never remove or reorder variables
    // above this line.
    uint256[50] private __gap;

    event DealCreated(uint256 indexed dealId, uint256 indexed playerId, address indexed buyingClub);
    event PlayerConsentRequested(uint256 indexed dealId, uint256 indexed playerId, address buyingClub);
    event PlayerConsented(uint256 indexed dealId, uint256 indexed playerId);
    event PlayerDeclined(uint256 indexed dealId, uint256 indexed playerId);
    event MedicalSubmitted(uint256 indexed dealId, TransferTypes.MedicalOutcome outcome);
    event MedicalRenegotiationStarted(uint256 indexed dealId);
    event MedicalRenegotiationResolved(uint256 indexed dealId, uint256 newFee);
    event MedicalDisputeEscalated(uint256 indexed dealId, address indexed escalatedBy);
    event MedicalDisputeResolved(uint256 indexed dealId);
    event CompetingBidActivated(uint256 indexed dealId, address indexed thirdParty, uint256 fee);
    event ThirdPartyMedicalCompleted(uint256 indexed dealId, address indexed thirdParty);
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
    event SigningBonusRescued(uint256 indexed dealId, address indexed to, uint256 amount);
    event AddOnDepositWithdrawn(uint256 indexed dealId, address indexed club, uint256 amount);

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
    error SigningBonusNotExpired();

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
            signingBonusAmount:        p.signingBonusAmount,
            signingBonusClaimed:       false,
            signingBonusExpiry:        0,
            state:                TransferTypes.DealState.AWAITING_PLAYER_CONSENT,
            stateDeadline:        block.timestamp + timers[0],
            medicalHash:          bytes32(0),
            frozen:               false,
            frozenAt:             0,
            originalBuyer:        address(0),
            mutualCancelProposer: address(0),
            mutualCancelDeadline: 0
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
        external onlyRole(LEAGUE_ROLE) dealExists(dealId)
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
            deal.state != TransferTypes.DealState.DISPUTE_WINDOW &&
            deal.state != TransferTypes.DealState.AWAITING_MEDICAL) revert WrongDealState();
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
        external onlyRole(LEAGUE_ROLE) dealExists(dealId)
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
        deal.medicalHash   = bytes32(0);
        deal.state         = TransferTypes.DealState.AWAITING_MEDICAL;
        deal.stateDeadline = block.timestamp + timers[1];
        emit MedicalRenegotiationResolved(dealId, newFee);
    }

    function rejectMedicalRenegotiation(uint256 dealId)
        external whenNotPaused dealExists(dealId) notFrozen(dealId)
    {
        Deal storage deal = _deals[dealId];
        if (deal.sellingClub != msg.sender)                             revert NotSellingClub();
        if (deal.state != TransferTypes.DealState.MEDICAL_RENEGOTIATION) revert WrongDealState();
        _cancelDeal(dealId, TransferTypes.CancelReason.MEDICAL_RENEGO_REJECTED);
    }

    function escalateToLeague(uint256 dealId)
        external whenNotPaused dealExists(dealId) notFrozen(dealId)
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
        // I block funding if Club A has accepted a competing bid that is unresolved.
        // Club B must match it first, then Club A must confirmOriginal before funding.
        if (competingBidManager != address(0) &&
            ICompetingBidManager(competingBidManager).hasActiveBid(dealId)) {
            revert WrongDealState();
        }
        if (block.timestamp > deal.stateDeadline)                   revert FundingWindowExpired();
        if (!ITransferWindow(addressRegistry.get(RegistryKeys.TRANSFER_WINDOW)).isWindowOpen())                         revert TransferWindowClosed();

        // I only require installment #0 + salary guarantee at funding — real-world practice
        uint256 firstInstallment = _installments[dealId][0].amount;
        uint256 totalRequired    = firstInstallment + deal.signingBonusAmount;
        // I pull the full first installment + signing bonus from the buyer.
        // Club B counter-deposit credit is handled by CompetingBidManager
        // via extCreditCounterDeposit before fundDeal is called.
        IERC20(deal.paymentToken).safeTransferFrom(
            msg.sender, address(this), totalRequired
        );
        _installments[dealId][0].paid = true;
        deal.state         = TransferTypes.DealState.AWAITING_MEDICAL;
        deal.stateDeadline = block.timestamp + timers[1];
        emit FundingReceived(dealId, msg.sender, totalRequired);
    }

    function getInstallment(uint256 dealId, uint8 index)
        external view returns (TransferTypes.Installment memory)
    {
        return _installments[dealId][index];
    }


    function raiseDispute(uint256 dealId)
        external whenNotPaused dealExists(dealId) notFrozen(dealId)
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
        external whenNotPaused dealExists(dealId) notFrozen(dealId)
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
        external whenNotPaused nonReentrant dealExists(dealId)
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
        if (deal.state != TransferTypes.DealState.AWAITING_PLAYER_CONSENT) revert WrongDealState();
        if (block.timestamp > deal.stateDeadline) revert ConsentWindowExpired();
        IPlayerRegistry.Player memory player = playerRegistry.getPlayer(deal.playerId);
        if (player.playerWallet == address(0)) revert PlayerWalletNotSet();
        if (player.playerWallet != msg.sender) revert NotPlayerWallet();
        // I move to FUNDING_PENDING — competing bids now open until Club B funds.
        deal.state         = TransferTypes.DealState.FUNDING_PENDING;
        deal.stateDeadline = block.timestamp + timers[5];
        deal.medicalHash   = bytes32(0);
        emit PlayerConsented(dealId, deal.playerId);
    }

    function declineTransfer(uint256 dealId)
        external whenNotPaused dealExists(dealId) notFrozen(dealId)
    {
        Deal storage deal = _deals[dealId];
        if (deal.state != TransferTypes.DealState.AWAITING_PLAYER_CONSENT)
            revert WrongDealState();
        IPlayerRegistry.Player memory player = playerRegistry.getPlayer(deal.playerId);
        if (player.playerWallet == address(0)) revert PlayerWalletNotSet();
        if (player.playerWallet != msg.sender) revert NotPlayerWallet();
        emit PlayerDeclined(dealId, deal.playerId);
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
        if (deal.state != TransferTypes.DealState.AWAITING_MEDICAL) revert WrongDealState();
        if (deal.buyingClub != msg.sender)         revert NotBuyingClub();
        if (block.timestamp > deal.stateDeadline) revert MedicalWindowExpired();
        if (deal.medicalHash != bytes32(0))        revert MedicalAlreadySubmitted();
        if (medicalHash == bytes32(0))             revert InvalidAddress();
        if (outcome == TransferTypes.MedicalOutcome.NONE) revert InvalidAmount();
        deal.medicalHash = medicalHash;
        emit MedicalSubmitted(dealId, outcome);

        if (outcome == TransferTypes.MedicalOutcome.PASSED) {
            // I settle immediately on medical pass — no post-medical window.
            // CompetingBidManager enforces that no accepted competing bid
            // is unresolved before submitMedical can be called.
            _settleDeal(dealId);
        } else if (outcome == TransferTypes.MedicalOutcome.FAILED) {
            // I cancel the deal on failed medical.
            // CompetingBidManager will handle activating a competing bid
            // if one exists — it calls extActivateThirdParty after this.
            _cancelDeal(dealId, TransferTypes.CancelReason.MEDICAL_FAILED);
        } else {
            deal.state         = TransferTypes.DealState.MEDICAL_RENEGOTIATION;
            deal.stateDeadline = block.timestamp + timers[4];
            emit MedicalRenegotiationStarted(dealId);
        }
    }


    function claimSigningBonus(uint256 dealId)
        external dealExists(dealId)
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


    function setCompetingBidManager(address mgr) external onlyRole(ADMIN_ROLE) {
        if (mgr == address(0)) revert InvalidAddress();
        competingBidManager = mgr;
    }

    // ─── CompetingBidManager Callbacks ────────────────────────────────────────

    /// @notice Credits an amount to a recipient's claimable balance.
    /// @dev    COMPETING_BID_MANAGER_ROLE only. Used to distribute competing
    ///         deposits: return to Club C, compensation to Club B, counter-deposit
    ///         return to Club B. Tokens must already be in this contract.
    function extCreditClaimable(
        address recipient,
        address token,
        uint256 amount
    )
        external
        onlyRole(COMPETING_BID_MANAGER_ROLE)
    {
        if (recipient == address(0)) revert InvalidAddress();
        if (amount == 0)             revert InvalidAmount();
        _claimable[recipient][token] += amount;
    }

    // ─── CompetingBidManager Callbacks ────────────────────────────────────────

    /// @notice Activates a third-party deal — switches buying club to Club C.
    /// @dev    COMPETING_BID_MANAGER_ROLE only. Called after Club A confirms switch.
    ///         Stores original buyer (Club B) for compensation tracking.
    ///         Resets medical hash, updates state to AWAITING_THIRD_PARTY_MEDICAL.
    function extActivateThirdParty(
        uint256 dealId,
        address thirdParty,
        uint256 newFee,
        uint256 buyerAgentBps,
        address buyerAgent,
        uint256 signingBonusMonths
    )
        external
        onlyRole(COMPETING_BID_MANAGER_ROLE)
        dealExists(dealId)
        nonReentrant
    {
        Deal storage deal = _deals[dealId];
        // I accept activation from AWAITING_MEDICAL (failed medical path)
        // or CANCELLED (medical failed, CompetingBidManager activates Club C).
        // The deal must not be frozen or completed.
        if (deal.state != TransferTypes.DealState.AWAITING_MEDICAL &&
            deal.state != TransferTypes.DealState.CANCELLED) revert WrongDealState();
        if (deal.frozen) revert DealIsFrozen();
        if (thirdParty == address(0))   revert InvalidAddress();
        if (newFee == 0)                revert InvalidAmount();

        // I preserve the original buyer for compensation tracking.
        // If originalBuyer is already set (re-activation) keep the first one.
        if (deal.originalBuyer == address(0)) {
            deal.originalBuyer = deal.buyingClub;
        }

        IPlayerRegistry.Player memory player = playerRegistry.getPlayer(deal.playerId);
        uint256 newSigningBonus = 0;
        if (signingBonusMonths > 0 && player.weeklySalary > 0) {
            newSigningBonus = player.weeklySalary * 4 * signingBonusMonths;
        }

        deal.buyingClub         = thirdParty;
        deal.transferFee        = newFee;
        deal.buyerAgentBps      = buyerAgentBps;
        deal.buyerAgent         = buyerAgent;
        deal.signingBonusAmount = newSigningBonus;
        deal.signingBonusClaimed = false;
        deal.medicalHash        = bytes32(0);
        // I move to AWAITING_MEDICAL — Club C has not had a medical yet.
        // They must pass medical before funding.
        deal.state              = TransferTypes.DealState.AWAITING_MEDICAL;
        deal.stateDeadline      = block.timestamp + timers[1];
        // I re-register the player deal mapping since _cancelDeal cleared it.
        _playerDeal[deal.playerId] = dealId;

        emit CompetingBidActivated(dealId, thirdParty, newFee);
        emit PlayerConsentRequested(dealId, deal.playerId, thirdParty);
    }

    /// @notice Credits Club B's counter-deposit toward their installment.
    /// @dev    COMPETING_BID_MANAGER_ROLE only. Called before Club B calls fundDeal.
    ///         Tokens must already be in DealEscrow before calling.
    function extCreditCounterDeposit(uint256 dealId, uint256 amount)
        external
        onlyRole(COMPETING_BID_MANAGER_ROLE)
        dealExists(dealId)
    {
        Deal storage deal = _deals[dealId];
        if (deal.state != TransferTypes.DealState.FUNDING_PENDING) revert WrongDealState();
        if (amount == 0) revert InvalidAmount();
        // I reduce the first installment by the counter-deposit amount.
        // fundDeal will then pull only the remainder from Club B.
        uint256 first = _installments[dealId][0].amount;
        if (amount > first) revert InvalidAmount();
        _installments[dealId][0].amount = first - amount;
    }

    // ─── External Callbacks (TRANSFER_ESCROW_ROLE only) ───────────────────────
    // processExpiry, expireMutualCancel, resolveDeadlock, walkAwayFromRenegotiation
    // live in TransferEscrow and call back here to mutate state.

    function extCancel(uint256 dealId, uint8 reason)
        external onlyRole(TRANSFER_ESCROW_ROLE) dealExists(dealId)
    {
        _cancelDeal(dealId, TransferTypes.CancelReason(reason));
    }

    function extAdvanceToFunding(uint256 dealId)
        external onlyRole(TRANSFER_ESCROW_ROLE) dealExists(dealId)
    {
        Deal storage deal  = _deals[dealId];
        deal.state         = TransferTypes.DealState.FUNDING_PENDING;
        deal.stateDeadline = block.timestamp + timers[5];
    }


    function extWalkAwayPenalty(uint256 dealId)
        external onlyRole(TRANSFER_ESCROW_ROLE) dealExists(dealId)
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

    // Rescue and add-on withdrawal are public wrappers on TransferEscrow;
    // state mutations and all error/event definitions stay here.
    function extRescueBonus(uint256 dealId, address dest)
        external onlyRole(TRANSFER_ESCROW_ROLE) dealExists(dealId)
    {
        Deal storage deal = _deals[dealId];
        if (deal.state != TransferTypes.DealState.COMPLETED) revert WrongDealState();
        if (deal.signingBonusAmount == 0)  revert NoSigningBonus();
        if (deal.signingBonusClaimed)       revert SigningBonusAlreadyClaimed();
        if (block.timestamp <= deal.signingBonusExpiry) revert SigningBonusNotExpired();
        deal.signingBonusClaimed = true;
        _claimable[dest][deal.paymentToken] += deal.signingBonusAmount;
        emit SigningBonusRescued(dealId, dest, deal.signingBonusAmount);
    }

    function extWithdrawAddOn(uint256 dealId, address buyer, uint256 amount)
        external onlyRole(TRANSFER_ESCROW_ROLE) dealExists(dealId)
    {
        Deal storage deal = _deals[dealId];
        uint256 available = _addOnDeposits[dealId][deal.paymentToken];
        if (amount > available) revert InvalidAmount();
        _addOnDeposits[dealId][deal.paymentToken] = available - amount;
        _claimable[buyer][deal.paymentToken] += amount;
        emit AddOnDepositWithdrawn(dealId, buyer, amount);
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
        Deal storage deal = _deals[dealId];
        TransferTypes.DealState prevState = deal.state;
        deal.state = TransferTypes.DealState.CANCELLED;
        _playerDeal[deal.playerId] = 0;
        if (prevState == TransferTypes.DealState.FUNDED ||
            prevState == TransferTypes.DealState.DISPUTE_WINDOW) {
            _claimable[deal.buyingClub][deal.paymentToken] +=
                _installments[dealId][0].amount + deal.signingBonusAmount;
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
        v.state                     = IDealEscrow.DealState(uint8(deal.state));
        v.stateDeadline             = deal.stateDeadline;
    }

    function getDealFull(uint256 dealId) external view returns (
        bool    exists,
        uint256 playerId,
        address sellingClub,
        address buyingClub,
        address paymentToken,
        uint256 transferFee,
        uint256 signingBonusAmount,
        bool    signingBonusClaimed,
        uint8   state,
        uint256 stateDeadline,
        address originalBuyer
    ) {
        Deal storage deal = _deals[dealId];
        if (deal.playerId == 0) return (false, 0, address(0), address(0), address(0), 0, 0, false, 0, 0, address(0));
        return (
            true,
            deal.playerId,
            deal.sellingClub,
            deal.buyingClub,
            deal.paymentToken,
            deal.transferFee,
            deal.signingBonusAmount,
            deal.signingBonusClaimed,
            uint8(deal.state),
            deal.stateDeadline,
            deal.originalBuyer
        );
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
