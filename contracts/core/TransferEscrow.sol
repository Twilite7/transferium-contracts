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
import "../types/TransferTypes.sol";

/**
 * @title TransferEscrow v2
 * @author Transferium Protocol
 * @notice Marketplace for permanent football transfers — offers, bids, negotiation.
 *
 * @dev Separated from DealEscrow to stay within the 24KB EIP-170 limit.
 *      TransferEscrow owns the marketplace phase (offers, bids, negotiation).
 *      When a bid is accepted, it calls DealEscrow.initializeDeal() and hands off.
 *      DealEscrow owns the full deal lifecycle from acceptance onwards.
 *
 * Security:
 *      - No funds locked at this stage — only intent (bids carry no deposits)
 *      - Transfer window enforced at offer creation
 *      - UUPS upgrade protected by DEFAULT_ADMIN_ROLE
 */
contract TransferEscrow is
    ProtocolFeeBase,
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using TransferTypes for *;

    // ─── Reentrancy Guard ─────────────────────────────────────────────────────
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;
    uint256 private _reentrancyStatus;

    modifier nonReentrant() {
        if (_reentrancyStatus == _ENTERED) revert ReentrantCall();
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }

    // ─── Roles ────────────────────────────────────────────────────────────────

    bytes32 public constant ADMIN_ROLE  = keccak256("ADMIN_ROLE");
    bytes32 public constant LEAGUE_ROLE = keccak256("LEAGUE_ROLE");
    bytes32 public constant CLUB_ROLE   = keccak256("CLUB_ROLE");

    // ─── Constants ────────────────────────────────────────────────────────────

    uint256 public constant MAX_SELL_ON_BPS          = 2000;
    uint256 public constant MAX_AGENT_BPS            = 300;
    uint256 public constant BPS_DENOMINATOR          = 10_000;
    uint256 public constant MAX_PRICE                = 500_000_000 ether;
    uint256 public constant MAX_ADDONS               = 10;
    uint256 public constant MAX_NEGOTIATION_ROUNDS   = 3;
    uint256 public constant MAX_ACTIVE_NEGOTIATIONS  = 5;
    uint256 public constant MAX_TOTAL_BIDS_PER_OFFER = 20;
    uint256 public constant MIN_CONSENT_WINDOW       = 1 hours;
    uint256 public constant LEAGUE_DISPUTE_DEADLINE  = 7 days;
    uint256 public constant HIJACK_FAIL_PENALTY_BPS  = 200;
    uint256 public constant HIJACK_STALL_PENALTY_BPS    = 500;
    // I cap salary guarantee months — a value like 10000 would produce an
    // unfundable signingBonusAmount that locks the deal in FUNDING_PENDING permanently
    uint256 public constant MAX_SIGNING_BONUS_MONTHS = 24;

    // ─── Enums ────────────────────────────────────────────────────────────────

    enum BidStatus {
        NONE,
        PENDING,
        NEGOTIATING,
        ACCEPTED,
        REJECTED,
        WITHDRAWN
    }

    // ─── Structs ──────────────────────────────────────────────────────────────

    struct Offer {
        uint256   playerId;
        address   sellingClub;
        address   paymentToken;
        uint256   askingPrice;
        uint256   sellOnBps;
        address   sellOnRecipient;
        uint256   sellerAgentBps;
        address   sellerAgent;
        uint256   minimumHijackIncrementBps;
        uint256   createdAt;
        uint256   activeNegotiations;
        bool      exists;
    }

    struct Bid {
        uint256   offerId;
        address   buyingClub;
        address   paymentToken;
        uint256   transferFee;
        uint256   sellOnBps;
        address   sellOnRecipient;
        uint256   sellerAgentBps;
        address   sellerAgent;
        uint256   buyerAgentBps;
        address   buyerAgent;
        uint256   signingBonusMonths;
        uint256[] installmentAmounts;
        uint256[] installmentDueDates;
        uint256   submittedAt;
        uint256   updatedAt;
        uint256   roundNumber;
        bool      isCounterFromSeller;
        BidStatus status;
    }

    struct TransferBan {
        uint256 windowsRemaining;
        bool    active;
    }

    // ─── State Variables ──────────────────────────────────────────────────────

    uint256 private _offerIdCounter;

    IPlayerRegistry public playerRegistry;
    IAddressRegistry public addressRegistry;
    IDealEscrow     public dealEscrow;

    mapping(address => uint256) public protocolFeesAccumulated;
    uint256 public consentWindow;

    mapping(uint256 => Offer)                           private _offers;
    mapping(uint256 => TransferTypes.AddOn[])           private _offerAddOns;
    mapping(uint256 => mapping(address => Bid))         private _bids;
    mapping(uint256 => address[])                       private _bidders;
    mapping(uint256 => uint256)                         private _bidCount;
    mapping(uint256 => uint256)                         private _playerOffer;
    mapping(address => bool)                            private _approvedTokens;
    address[]                                           private _approvedTokenList;
    mapping(address => TransferBan)                     private _transferBans;

    // ─── Events ───────────────────────────────────────────────────────────────

    event OfferCreated(uint256 indexed offerId, uint256 indexed playerId, address indexed sellingClub, uint256 askingPrice);
    event OfferUpdated(uint256 indexed offerId, uint256 newAskingPrice);
    event OfferWithdrawn(uint256 indexed offerId);
    event BidSubmitted(uint256 indexed offerId, address indexed buyingClub, uint256 transferFee, BidStatus status);
    event BidUpdated(uint256 indexed offerId, address indexed buyingClub, uint256 newTransferFee);
    event BidWithdrawn(uint256 indexed offerId, address indexed buyingClub);
    event BidRejected(uint256 indexed offerId, address indexed buyingClub);
    event BidActivated(uint256 indexed offerId, address indexed buyingClub);
    event CounterOffer(uint256 indexed offerId, address indexed from, uint256 newFee, uint256 round);
    event BidAccepted(uint256 indexed offerId, uint256 indexed dealId, address indexed buyingClub);
    event TokenApproved(address indexed token);
    event TokenRevoked(address indexed token);
    event TransferBanIssued(address indexed club, uint256 windows);
    event TransferBanLifted(address indexed club);
    event BanWindowDecremented(address indexed club, uint256 windowsRemaining);
    event TreasuryUpdated(address indexed newTreasury);
    event MutualCancelExpired(uint256 indexed dealId);
    event DealCancelled(uint256 indexed dealId, uint8 reason);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error InvalidAddress();
    error NothingToWithdraw();
    error InsufficientProtocolBalance(uint256 requested, uint256 available);
    error InvalidAmount();
    error InvalidBps();
    error TokenNotApproved();
    error TokenAlreadyApproved();
    error TokenNotInList();
    error TransferWindowClosed();
    error PlayerHasActiveOffer();
    error PlayerHasActiveDeal();
    error OfferNotFound();
    error BidNotFound();
    error WrongDealState();
    error NotSellingClub();
    error CannotBidOnOwnPlayer();
    error MaxNegotiationsReached();
    error MaxNegotiationRoundsReached();
    error NotYourTurnToCounter();
    error BidCanOnlyBeUpdatedWhenNegotiating();
    error ClubTransferBanned();
    error AlreadyHasActiveBid();
    error BanAlreadyActive();
    error NoBanToLift();
    error NoBanToDecrement();
    error TooManyAddOns();
    error TimerTooShort();
    error ReentrantCall();
    error DealNotFound();
    error HijackWindowClosed();
    error CannotHijackOwnDeal();
    error BidNotHighEnough(uint256 minimum, uint256 submitted);
    error DealIsFrozen();

    // ─── Initializer ──────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(
        address _playerRegistry,
        address _addressRegistry,
        address _dealEscrow,
        address _treasury,
        address _admin
    ) external initializer {
        if (_playerRegistry == address(0)) revert InvalidAddress();
        if (_addressRegistry == address(0)) revert InvalidAddress();
        if (_dealEscrow      == address(0)) revert InvalidAddress();
        if (_treasury        == address(0)) revert InvalidAddress();
        if (_admin           == address(0)) revert InvalidAddress();

        __AccessControl_init();
        __Pausable_init();
        _reentrancyStatus = _NOT_ENTERED;

        playerRegistry = IPlayerRegistry(_playerRegistry);
        addressRegistry = IAddressRegistry(_addressRegistry);
        dealEscrow     = IDealEscrow(_dealEscrow);
        treasury       = _treasury;

        consentWindow  = 72 hours;
        protocolFeeBps = 50;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE,         _admin);
        _grantRole(LEAGUE_ROLE,        _admin);
    }

    function _authorizeUpgrade(address)
        internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier offerExists(uint256 offerId) {
        if (!_offers[offerId].exists) revert OfferNotFound();
        _;
    }

    modifier onlyApprovedToken(address token) {
        if (!_approvedTokens[token]) revert TokenNotApproved();
        _;
    }

    modifier notBanned() {
        if (_transferBans[msg.sender].active) revert ClubTransferBanned();
        _;
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function approveToken(address token) external onlyRole(ADMIN_ROLE) {
        if (token == address(0))    revert InvalidAddress();
        if (_approvedTokens[token]) revert TokenAlreadyApproved();
        _approvedTokens[token] = true;
        _approvedTokenList.push(token);
        emit TokenApproved(token);
    }

    function revokeToken(address token) external onlyRole(ADMIN_ROLE) {
        if (!_approvedTokens[token]) revert TokenNotInList();
        _approvedTokens[token] = false;
        uint256 len = _approvedTokenList.length;
        for (uint256 i = 0; i < len; i++) {
            if (_approvedTokenList[i] == token) {
                _approvedTokenList[i] = _approvedTokenList[len - 1];
                _approvedTokenList.pop();
                break;
            }
        }
        emit TokenRevoked(token);
    }

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
        uint256 avail = protocolFeesAccumulated[token];
        if (amount > avail) revert InsufficientProtocolBalance(amount, avail);
        protocolFeesAccumulated[token] = avail - amount;
        IERC20(token).safeTransfer(treasury, amount);
        emit ProtocolFeesWithdrawn(treasury, token, amount);
    }

    function setConsentWindow(uint256 duration) external onlyRole(ADMIN_ROLE) {
        if (duration < MIN_CONSENT_WINDOW) revert TimerTooShort();
        consentWindow = duration;
    }

    function pause()   external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    // ─── League: Ban Management ───────────────────────────────────────────────

    function issueBan(address club, uint256 windows) external onlyRole(LEAGUE_ROLE) {
        if (club == address(0))         revert InvalidAddress();
        if (windows == 0)               revert InvalidAmount();
        if (_transferBans[club].active) revert BanAlreadyActive();
        _transferBans[club] = TransferBan({ windowsRemaining: windows, active: true });
        emit TransferBanIssued(club, windows);
    }

    function liftBan(address club) external onlyRole(LEAGUE_ROLE) {
        if (!_transferBans[club].active) revert NoBanToLift();
        _transferBans[club].active = false;
        emit TransferBanLifted(club);
    }

    /**
     * @notice Decrement ban counters when a new window opens.
     * @dev Caller responsible for passing unique addresses — duplicates
     *      will decrement the same club twice in one call.
     */
    function processNewWindow(address[] calldata bannedClubs)
        external onlyRole(LEAGUE_ROLE)
    {
        uint256 len = bannedClubs.length;
        // I reject duplicates before processing — a duplicate would decrement one club twice
        for (uint256 i = 0; i < len; i++) {
            for (uint256 j = i + 1; j < len; j++) {
                if (bannedClubs[i] == bannedClubs[j]) revert InvalidAddress();
            }
        }
        for (uint256 i = 0; i < len; i++) {
            TransferBan storage ban = _transferBans[bannedClubs[i]];
            if (!ban.active) revert NoBanToDecrement();
            if (ban.windowsRemaining > 0) {
                ban.windowsRemaining--;
                emit BanWindowDecremented(bannedClubs[i], ban.windowsRemaining);
            }
            if (ban.windowsRemaining == 0) {
                ban.active = false;
                emit TransferBanLifted(bannedClubs[i]);
            }
        }
    }

    // ─── Selling Club Functions ───────────────────────────────────────────────

    /**
     * @notice Create a transfer offer for a player.
     * @dev Window must be open. One active offer per player.
     */
    function createOffer(
        uint256  playerId,
        address  paymentToken,
        uint256  askingPrice,
        uint256  sellOnBps,
        address  sellOnRecipient,
        uint256  sellerAgentBps,
        address  sellerAgent,
        uint256  minimumHijackIncrementBps,
        TransferTypes.AddOn[] calldata addOns
    )
        external
        whenNotPaused
        nonReentrant
        onlyRole(CLUB_ROLE)
        onlyApprovedToken(paymentToken)
        returns (uint256 offerId)
    {
        if (!ITransferWindow(addressRegistry.get(RegistryKeys.TRANSFER_WINDOW)).isWindowOpen())                   revert TransferWindowClosed();
        if (_playerOffer[playerId] != 0)                      revert PlayerHasActiveOffer();
        // I check DealEscrow for active deal — it owns _playerDeal after split
        if (dealEscrow.getPlayerDeal(playerId) != 0)          revert PlayerHasActiveDeal();
        if (playerRegistry.currentClub(playerId) != msg.sender) revert NotSellingClub();

        if (askingPrice == 0 || askingPrice > MAX_PRICE)       revert InvalidAmount();
        if (sellOnBps > MAX_SELL_ON_BPS)                        revert InvalidBps();
        if (sellOnBps > 0 && sellOnRecipient == address(0))     revert InvalidAddress();
        if (sellerAgentBps > MAX_AGENT_BPS)                     revert InvalidBps();
        if (sellerAgentBps > 0 && sellerAgent == address(0))    revert InvalidAddress();
        if (minimumHijackIncrementBps == 0 ||
            minimumHijackIncrementBps > BPS_DENOMINATOR)        revert InvalidBps();
        if (addOns.length > MAX_ADDONS)                         revert TooManyAddOns();

        for (uint256 i = 0; i < addOns.length; i++) {
            if (bytes(addOns[i].description).length == 0 ||
                bytes(addOns[i].description).length > 256) revert InvalidAmount();
            if (addOns[i].amount == 0) revert InvalidAmount();
        }

        _offerIdCounter++;
        offerId = _offerIdCounter;

        _offers[offerId] = Offer({
            playerId:                  playerId,
            sellingClub:               msg.sender,
            paymentToken:              paymentToken,
            askingPrice:               askingPrice,
            sellOnBps:                 sellOnBps,
            sellOnRecipient:           sellOnRecipient,
            sellerAgentBps:            sellerAgentBps,
            sellerAgent:               sellerAgent,
            minimumHijackIncrementBps: minimumHijackIncrementBps,
            createdAt:                 block.timestamp,
            activeNegotiations:        0,
            exists:                    true
        });

        for (uint256 i = 0; i < addOns.length; i++) {
            _offerAddOns[offerId].push(addOns[i]);
        }

        _playerOffer[playerId] = offerId;
        emit OfferCreated(offerId, playerId, msg.sender, askingPrice);
    }

    function updateOffer(
        uint256 offerId,
        uint256 newAskingPrice,
        uint256 newSellOnBps,
        address newSellOnRecipient,
        uint256 newSellerAgentBps,
        address newSellerAgent,
        uint256 newMinimumHijackIncrementBps
    )
        external whenNotPaused nonReentrant offerExists(offerId)
    {
        Offer storage offer = _offers[offerId];
        if (offer.sellingClub != msg.sender) revert NotSellingClub();
        if (offer.activeNegotiations > 0)    revert WrongDealState();

        if (newAskingPrice == 0 || newAskingPrice > MAX_PRICE)      revert InvalidAmount();
        if (newSellOnBps > MAX_SELL_ON_BPS)                          revert InvalidBps();
        if (newSellOnBps > 0 && newSellOnRecipient == address(0))    revert InvalidAddress();
        if (newSellerAgentBps > MAX_AGENT_BPS)                       revert InvalidBps();
        if (newSellerAgentBps > 0 && newSellerAgent == address(0))   revert InvalidAddress();
        if (newMinimumHijackIncrementBps == 0 ||
            newMinimumHijackIncrementBps > BPS_DENOMINATOR)          revert InvalidBps();

        offer.askingPrice               = newAskingPrice;
        offer.sellOnBps                 = newSellOnBps;
        offer.sellOnRecipient           = newSellOnRecipient;
        offer.sellerAgentBps            = newSellerAgentBps;
        offer.sellerAgent               = newSellerAgent;
        offer.minimumHijackIncrementBps = newMinimumHijackIncrementBps;

        // I emit so PENDING bidders know terms changed and can withdraw if they disagree
        emit OfferUpdated(offerId, newAskingPrice);
    }

    function withdrawOffer(uint256 offerId)
        external whenNotPaused nonReentrant offerExists(offerId)
    {
        Offer storage offer = _offers[offerId];
        if (offer.sellingClub != msg.sender) revert NotSellingClub();
        if (offer.activeNegotiations > 0)    revert WrongDealState();

        offer.exists = false;
        _playerOffer[offer.playerId] = 0;
        emit OfferWithdrawn(offerId);
    }

    /**
     * @notice Accept a bid — creates the deal in DealEscrow and hands off.
     * @dev Front-running note: selling club specifies buyingClub by address,
     *      not by best price. Their choice is honoured regardless of other bids.
     *      BID_ACCEPTED is irrevocable — DealEscrow owns the deal from here.
     */
    function acceptBid(uint256 offerId, address buyingClub)
        external whenNotPaused nonReentrant offerExists(offerId)
    {
        Offer storage offer = _offers[offerId];
        if (offer.sellingClub != msg.sender) revert NotSellingClub();

        Bid storage bid = _bids[offerId][buyingClub];
        if (bid.status != BidStatus.NEGOTIATING) revert BidNotFound();
        // I block accept while a seller counter-offer is pending — buyer must call updateBid
        // first to acknowledge the new terms before seller can lock them in via acceptBid
        if (bid.isCounterFromSeller) revert NotYourTurnToCounter();

        IPlayerRegistry.Player memory player = playerRegistry.getPlayer(offer.playerId);
        uint256 signingBonusAmount = 0;
        if (bid.signingBonusMonths > 0 && player.weeklySalary > 0) {
            signingBonusAmount = player.weeklySalary * 4 * bid.signingBonusMonths;
        }

        // I build params struct to avoid stack-too-deep on initializeDeal
        TransferTypes.DealInitParams memory params = TransferTypes.DealInitParams({
            offerId:                   offerId,
            playerId:                  offer.playerId,
            sellingClub:               offer.sellingClub,
            buyingClub:                buyingClub,
            paymentToken:              offer.paymentToken,
            transferFee:               bid.transferFee,
            sellOnBps:                 bid.sellOnBps,
            sellOnRecipient:           bid.sellOnRecipient,
            sellerAgentBps:            bid.sellerAgentBps,
            sellerAgent:               bid.sellerAgent,
            buyerAgentBps:             bid.buyerAgentBps,
            buyerAgent:                bid.buyerAgent,
            signingBonusMonths:     bid.signingBonusMonths,
            signingBonusAmount:     signingBonusAmount,
            minimumHijackIncrementBps: offer.minimumHijackIncrementBps,
            consentWindowDuration:     consentWindow,
            installmentAmounts:        bid.installmentAmounts,
            installmentDueDates:       bid.installmentDueDates
        });

        // I get add-ons from offer storage to pass to DealEscrow
        TransferTypes.AddOn[] storage offerAddOns = _offerAddOns[offerId];

        // I reject all other active/pending bids before handing off
        address[] storage bidders = _bidders[offerId];
        for (uint256 i = 0; i < bidders.length; i++) {
            if (bidders[i] == buyingClub) continue;
            Bid storage other = _bids[offerId][bidders[i]];
            if (other.status == BidStatus.NEGOTIATING ||
                other.status == BidStatus.PENDING) {
                other.status = BidStatus.REJECTED;
                emit BidRejected(offerId, bidders[i]);
            }
        }

        bid.status         = BidStatus.ACCEPTED;
        offer.exists       = false;
        _bidCount[offerId] = 0;
        _playerOffer[offer.playerId] = 0;

        // I hand off to DealEscrow — it creates the deal and owns the lifecycle
        uint256 dealId = dealEscrow.initializeDeal(params, offerAddOns);

        emit BidAccepted(offerId, dealId, buyingClub);
    }

    function rejectBid(uint256 offerId, address buyingClub)
        external whenNotPaused nonReentrant offerExists(offerId)
    {
        Offer storage offer = _offers[offerId];
        if (offer.sellingClub != msg.sender) revert NotSellingClub();

        Bid storage bid = _bids[offerId][buyingClub];
        if (bid.status != BidStatus.NEGOTIATING &&
            bid.status != BidStatus.PENDING) revert BidNotFound();

        bool wasNegotiating = bid.status == BidStatus.NEGOTIATING;
        bid.status = BidStatus.REJECTED;
        if (wasNegotiating && offer.activeNegotiations > 0) offer.activeNegotiations--;
        _bidCount[offerId]--;

        emit BidRejected(offerId, buyingClub);

        if (wasNegotiating) _activateNextPendingBid(offerId);
    }

    // ─── Buying Club Functions ────────────────────────────────────────────────

    function submitBid(
        uint256   offerId,
        uint256   transferFee,
        uint256   sellOnBps,
        address   sellOnRecipient,
        uint256   sellerAgentBps,
        address   sellerAgent,
        uint256   buyerAgentBps,
        address   buyerAgent,
        uint256   signingBonusMonths,
        uint256[] calldata installmentAmounts,
        uint256[] calldata installmentDueDates
    )
        external whenNotPaused nonReentrant onlyRole(CLUB_ROLE) offerExists(offerId) notBanned
    {
        Offer storage offer = _offers[offerId];
        if (offer.sellingClub == msg.sender) revert CannotBidOnOwnPlayer();
        if (_bidCount[offerId] >= MAX_TOTAL_BIDS_PER_OFFER) revert MaxNegotiationsReached();

        Bid storage existing = _bids[offerId][msg.sender];
        if (existing.status == BidStatus.NEGOTIATING ||
            existing.status == BidStatus.PENDING) revert AlreadyHasActiveBid();

        if (transferFee == 0 || transferFee > MAX_PRICE)     revert InvalidAmount();
        if (sellOnBps > MAX_SELL_ON_BPS)                      revert InvalidBps();
        if (sellOnBps > 0 && sellOnRecipient == address(0))   revert InvalidAddress();
        if (sellerAgentBps > MAX_AGENT_BPS)                   revert InvalidBps();
        if (sellerAgentBps > 0 && sellerAgent == address(0))  revert InvalidAddress();
        if (buyerAgentBps > MAX_AGENT_BPS)                                   revert InvalidBps();
        if (buyerAgentBps > 0 && buyerAgent == address(0))                   revert InvalidAddress();
        // I cap salary guarantee months — 24 months covers any realistic guarantee clause
        if (signingBonusMonths > MAX_SIGNING_BONUS_MONTHS)             revert InvalidAmount();
        // I validate installment schedule upfront — DealEscrow will re-validate but fail early here
        if (installmentAmounts.length == 0 || installmentAmounts.length > 8) revert InvalidAmount();
        if (installmentDueDates.length != installmentAmounts.length)          revert InvalidAmount();
        uint256 _instSum = 0;
        for (uint256 i = 0; i < installmentAmounts.length; i++) {
            if (installmentAmounts[i] == 0) revert InvalidAmount();
            // I require due dates to be in the future and strictly increasing
            if (i == 0 && installmentDueDates[0] < block.timestamp) revert InvalidAmount();
            if (i > 0 && installmentDueDates[i] <= installmentDueDates[i-1]) revert InvalidAmount();
            _instSum += installmentAmounts[i];
        }
        if (_instSum != transferFee) revert InvalidAmount();

        BidStatus status = offer.activeNegotiations < MAX_ACTIVE_NEGOTIATIONS
            ? BidStatus.NEGOTIATING
            : BidStatus.PENDING;

        Bid storage newBid = _bids[offerId][msg.sender];
        newBid.offerId               = offerId;
        newBid.buyingClub            = msg.sender;
        newBid.paymentToken          = offer.paymentToken;
        newBid.transferFee           = transferFee;
        newBid.sellOnBps             = sellOnBps;
        newBid.sellOnRecipient       = sellOnRecipient;
        newBid.sellerAgentBps        = sellerAgentBps;
        newBid.sellerAgent           = sellerAgent;
        newBid.buyerAgentBps         = buyerAgentBps;
        newBid.buyerAgent            = buyerAgent;
        newBid.signingBonusMonths = signingBonusMonths;
        newBid.submittedAt           = block.timestamp;
        newBid.updatedAt             = block.timestamp;
        newBid.roundNumber           = 0;
        newBid.isCounterFromSeller   = false;
        newBid.status                = status;
        // I copy arrays explicitly — Solidity can't assign dynamic arrays in struct literals
        delete newBid.installmentAmounts;
        delete newBid.installmentDueDates;
        for (uint256 i = 0; i < installmentAmounts.length; i++) {
            newBid.installmentAmounts.push(installmentAmounts[i]);
            newBid.installmentDueDates.push(installmentDueDates[i]);
        }

        if (existing.submittedAt == 0) _bidders[offerId].push(msg.sender);
        _bidCount[offerId]++;
        if (status == BidStatus.NEGOTIATING) offer.activeNegotiations++;

        emit BidSubmitted(offerId, msg.sender, transferFee, status);
    }

    function updateBid(
        uint256 offerId,
        uint256 newTransferFee,
        uint256 newSellOnBps,
        address newSellOnRecipient,
        uint256 newSellerAgentBps,
        address newSellerAgent,
        uint256 newBuyerAgentBps,
        address newBuyerAgent,
        uint256 newSalaryGuaranteeMonths
    )
        external whenNotPaused nonReentrant offerExists(offerId)
    {
        Bid storage bid = _bids[offerId][msg.sender];
        if (bid.status != BidStatus.NEGOTIATING)           revert BidCanOnlyBeUpdatedWhenNegotiating();
        if (bid.roundNumber >= MAX_NEGOTIATION_ROUNDS)     revert MaxNegotiationRoundsReached();
        if (!bid.isCounterFromSeller && bid.roundNumber > 0) revert NotYourTurnToCounter();

        if (newTransferFee == 0 || newTransferFee > MAX_PRICE)    revert InvalidAmount();
        if (newSellOnBps > MAX_SELL_ON_BPS)                        revert InvalidBps();
        if (newSellOnBps > 0 && newSellOnRecipient == address(0))  revert InvalidAddress();
        if (newSellerAgentBps > MAX_AGENT_BPS)                     revert InvalidBps();
        if (newSellerAgentBps > 0 && newSellerAgent == address(0)) revert InvalidAddress();
        if (newBuyerAgentBps > MAX_AGENT_BPS)                                 revert InvalidBps();
        if (newBuyerAgentBps > 0 && newBuyerAgent == address(0))              revert InvalidAddress();
        if (newSalaryGuaranteeMonths > MAX_SIGNING_BONUS_MONTHS)           revert InvalidAmount();

        bid.transferFee           = newTransferFee;
        bid.sellOnBps             = newSellOnBps;
        bid.sellOnRecipient       = newSellOnRecipient;
        bid.sellerAgentBps        = newSellerAgentBps;
        bid.sellerAgent           = newSellerAgent;
        bid.buyerAgentBps         = newBuyerAgentBps;
        bid.buyerAgent            = newBuyerAgent;
        bid.signingBonusMonths = newSalaryGuaranteeMonths;
        bid.roundNumber++;
        bid.isCounterFromSeller   = false;
        bid.updatedAt             = block.timestamp;

        emit BidUpdated(offerId, msg.sender, newTransferFee);
    }

    function counterBid(
        uint256 offerId,
        address buyingClub,
        uint256 newTransferFee,
        uint256 newSellOnBps,
        address newSellOnRecipient,
        uint256 newSellerAgentBps,
        address newSellerAgent
    )
        external whenNotPaused nonReentrant offerExists(offerId)
    {
        Offer storage offer = _offers[offerId];
        if (offer.sellingClub != msg.sender) revert NotSellingClub();

        Bid storage bid = _bids[offerId][buyingClub];
        if (bid.status != BidStatus.NEGOTIATING)       revert BidNotFound();
        if (bid.roundNumber >= MAX_NEGOTIATION_ROUNDS) revert MaxNegotiationRoundsReached();
        if (bid.isCounterFromSeller)                   revert NotYourTurnToCounter();

        if (newTransferFee == 0 || newTransferFee > MAX_PRICE)     revert InvalidAmount();
        if (newSellOnBps > MAX_SELL_ON_BPS)                         revert InvalidBps();
        if (newSellOnBps > 0 && newSellOnRecipient == address(0))   revert InvalidAddress();
        if (newSellerAgentBps > MAX_AGENT_BPS)                      revert InvalidBps();
        if (newSellerAgentBps > 0 && newSellerAgent == address(0))  revert InvalidAddress();

        bid.transferFee         = newTransferFee;
        bid.sellOnBps           = newSellOnBps;
        bid.sellOnRecipient     = newSellOnRecipient;
        bid.sellerAgentBps      = newSellerAgentBps;
        bid.sellerAgent         = newSellerAgent;
        bid.roundNumber++;
        bid.isCounterFromSeller = true;
        bid.updatedAt           = block.timestamp;

        emit CounterOffer(offerId, msg.sender, newTransferFee, bid.roundNumber);
    }

    function withdrawBid(uint256 offerId)
        external whenNotPaused nonReentrant offerExists(offerId)
    {
        Bid storage bid = _bids[offerId][msg.sender];
        if (bid.status != BidStatus.NEGOTIATING &&
            bid.status != BidStatus.PENDING) revert BidNotFound();

        bool wasNegotiating = bid.status == BidStatus.NEGOTIATING;
        bid.status = BidStatus.WITHDRAWN;

        Offer storage offer = _offers[offerId];
        if (wasNegotiating && offer.activeNegotiations > 0) offer.activeNegotiations--;
        _bidCount[offerId]--;

        emit BidWithdrawn(offerId, msg.sender);

        if (wasNegotiating) _activateNextPendingBid(offerId);
    }

    // ─── Hijack Bid Submission ────────────────────────────────────────────────

    /**
     * @notice Submit a hijack bid on an agreed deal.
     * @dev Validates bid, pulls full funding, refunds previous hijacker if any,
     *      then delegates storage update to DealEscrow via TRANSFER_ESCROW_ROLE.
     *      Kept in TransferEscrow to stay within DealEscrow's 24KB size limit.
     */
    function submitHijackBid(
        uint256 dealId,
        uint256 transferFee,
        uint256 buyerAgentBps,
        address buyerAgent,
        uint256 signingBonusMonths
    )
        external
        whenNotPaused
        nonReentrant
        onlyRole(CLUB_ROLE)
        notBanned
    {
        // I pull deal data via interface to check state
        IDealEscrow.DealView memory dv = dealEscrow.getDealView(dealId);
        if (!dv.exists)                              revert DealNotFound();
        if (dv.state != IDealEscrow.DealState.HIJACK_WINDOW) revert HijackWindowClosed();
        if (block.timestamp > dv.stateDeadline)     revert HijackWindowClosed();
        if (msg.sender == dv.sellingClub)            revert CannotBidOnOwnPlayer();
        if (msg.sender == dv.buyingClub)             revert CannotHijackOwnDeal();

        uint256 minimumFee = dv.transferFee +
            (dv.transferFee * dv.minimumHijackIncrementBps) / BPS_DENOMINATOR;
        if (transferFee < minimumFee) revert BidNotHighEnough(minimumFee, transferFee);

        if (buyerAgentBps > MAX_AGENT_BPS)                 revert InvalidBps();
        if (buyerAgentBps > 0 && buyerAgent == address(0)) revert InvalidAddress();

        // I send funds directly to DealEscrow — it holds all hijack funds.
        // Previous hijacker is refunded internally via DealEscrow._claimable.
        // This avoids cross-contract fund forwarding complexity.
        IERC20(dv.paymentToken).safeTransferFrom(msg.sender, address(dealEscrow), transferFee);

        // I record the bid in DealEscrow storage after funds arrive
        dealEscrow.receiveHijackBid(
            dealId, msg.sender, transferFee, buyerAgentBps, buyerAgent, signingBonusMonths
        );
    }

    // ─── Renegotiation / Dispute Resolution ─────────────────────────────────

    /**
     * @notice Buying club walks away from medical renegotiation.
     * @dev No penalty — no funds are locked at MEDICAL_RENEGOTIATION stage.
     */
    function walkAwayFromRenegotiation(uint256 dealId)
        external whenNotPaused nonReentrant
    {
        IDealEscrow.DealView memory dv = dealEscrow.getDealView(dealId);
        if (!dv.exists) revert DealNotFound();
        uint8 MEDICAL_RENEGOTIATION = 7;
        if (uint8(dv.state) != MEDICAL_RENEGOTIATION) revert WrongDealState();
        if (msg.sender != dv.buyingClub) revert DealNotFound();
        dealEscrow.extWalkAwayPenalty(dealId);
    }

    /**
     * @notice League resolves a medical dispute.
     * @dev op 0 = cancel, op 1 = advance to hijack at original fee,
     *      op 2 = advance to hijack at league-set fee.
     */
    function resolveDeadlock(uint256 dealId, uint8 op, uint256 newFee)
        external whenNotPaused nonReentrant onlyRole(LEAGUE_ROLE)
    {
        IDealEscrow.DealView memory dv = dealEscrow.getDealView(dealId);
        if (!dv.exists) revert DealNotFound();
        uint8 MEDICAL_DISPUTE = 8;
        if (uint8(dv.state) != MEDICAL_DISPUTE) revert WrongDealState();
        if (op == 0) {
            dealEscrow.extCancel(dealId, uint8(TransferTypes.CancelReason.LEAGUE_DISPUTE_CANCELLED));
        } else if (op == 1) {
            dealEscrow.extAdvanceToHijack(dealId, 0);
        } else if (op == 2) {
            if (newFee == 0) revert InvalidAmount();
            dealEscrow.extAdvanceToHijack(dealId, newFee);
        } else {
            revert InvalidAmount();
        }
    }

    // ─── Expiry Processing ────────────────────────────────────────────────────

    /**
     * @notice Process an expired deal state. Anyone can call to unstick a deal.
     * @dev Moved here from DealEscrow to stay within DealEscrow's 24KB limit.
     *      Reads state via getExpiryView, delegates mutations back to DealEscrow
     *      via role-gated callbacks (TRANSFER_ESCROW_ROLE).
     */
    function processExpiry(uint256 dealId) external nonReentrant {
        (
            bool    exists,
            bool    frozen,
            uint8   state,
            uint256 stateDeadline,
            ,
        ) = dealEscrow.getExpiryView(dealId);

        if (!exists)                           revert DealNotFound();
        if (frozen)                            revert DealIsFrozen();
        if (stateDeadline == 0)                revert WrongDealState();
        if (block.timestamp <= stateDeadline)  revert WrongDealState();

        // I map uint8 state to the enum values we care about
        // Values match TransferTypes.DealState order exactly
        uint8 AWAITING_PLAYER_CONSENT    = 5;
        uint8 AWAITING_TRANSFER_MEDICAL  = 6;
        uint8 MEDICAL_RENEGOTIATION      = 7;
        uint8 MEDICAL_DISPUTE            = 8;
        uint8 HIJACK_WINDOW              = 9;
        uint8 AWAITING_HIJACK_CONSENT    = 10;
        uint8 AWAITING_HIJACK_MEDICAL    = 11;
        uint8 FUNDING_PENDING            = 13;
        uint8 FUNDED                     = 14;
        uint8 DISPUTE_WINDOW             = 15;

        if (state == AWAITING_PLAYER_CONSENT || state == AWAITING_HIJACK_CONSENT) {
            dealEscrow.extCancel(dealId, uint8(TransferTypes.CancelReason.CONSENT_WINDOW_EXPIRED));
        } else if (state == AWAITING_TRANSFER_MEDICAL) {
            dealEscrow.extCancel(dealId, uint8(TransferTypes.CancelReason.MEDICAL_WINDOW_EXPIRED));
        } else if (state == AWAITING_HIJACK_MEDICAL) {
            dealEscrow.extHijackStallAndCancel(dealId);
        } else if (state == MEDICAL_RENEGOTIATION) {
            dealEscrow.extCancel(dealId, uint8(TransferTypes.CancelReason.RENEGO_NO_RESOLUTION));
        } else if (state == MEDICAL_DISPUTE) {
            dealEscrow.extCancel(dealId, uint8(TransferTypes.CancelReason.LEAGUE_DEADLINE_EXPIRED));
        } else if (state == HIJACK_WINDOW) {
            dealEscrow.extAdvanceToFunding(dealId);
        } else if (state == FUNDED) {
            // Dispute window expired with no dispute raised — settle automatically
            dealEscrow.extSettle(dealId);
        } else if (state == DISPUTE_WINDOW) {
            // League never resolved the dispute before deadline — auto-settle
            dealEscrow.extSettle(dealId);
        } else if (state == FUNDING_PENDING) {
            dealEscrow.extCancel(dealId, uint8(TransferTypes.CancelReason.FUNDING_WINDOW_EXPIRED));
        } else {
            revert WrongDealState();
        }
    }

    /**
     * @notice Clear an expired mutual cancel proposal. Anyone can call.
     */
    function expireMutualCancel(uint256 dealId) external {
        (
            bool    exists,
            ,
            ,
            ,
            uint256 mutualCancelDeadline,
            address mutualCancelProposer
        ) = dealEscrow.getExpiryView(dealId);

        if (!exists)                                 revert DealNotFound();
        if (mutualCancelProposer == address(0))      revert WrongDealState();
        if (block.timestamp <= mutualCancelDeadline) revert WrongDealState();

        dealEscrow.extClearMutualCancel(dealId);
        emit MutualCancelExpired(dealId);
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _activateNextPendingBid(uint256 offerId) internal {
        Offer storage offer = _offers[offerId];
        if (!offer.exists) return;
        if (offer.activeNegotiations >= MAX_ACTIVE_NEGOTIATIONS) return;

        address[] storage bidders = _bidders[offerId];
        uint256 len = bidders.length;
        for (uint256 i = 0; i < len; i++) {
            Bid storage bid = _bids[offerId][bidders[i]];
            if (bid.status == BidStatus.PENDING) {
                bid.status = BidStatus.NEGOTIATING;
                offer.activeNegotiations++;
                emit BidActivated(offerId, bidders[i]);
                return;
            }
        }
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    function getOffer(uint256 offerId)
        external view offerExists(offerId) returns (Offer memory) {
        return _offers[offerId];
    }

    function getOfferAddOns(uint256 offerId)
        external view offerExists(offerId) returns (TransferTypes.AddOn[] memory) {
        return _offerAddOns[offerId];
    }

    /**
     * @notice Selling club sees full bid details. Buying club sees their own bid.
     * @dev UI-level privacy only — raw storage is always public on-chain.
     */
    function getBid(uint256 offerId, address buyingClub)
        external view returns (Bid memory) {
        Offer storage offer = _offers[offerId];
        if (msg.sender != offer.sellingClub && msg.sender != buyingClub)
            revert NotSellingClub();
        return _bids[offerId][buyingClub];
    }

    function getBidCount(uint256 offerId) external view returns (uint256) {
        return _bidCount[offerId];
    }

    function getAllBids(uint256 offerId)
        external view offerExists(offerId) returns (Bid[] memory) {
        if (msg.sender != _offers[offerId].sellingClub) revert NotSellingClub();

        address[] storage bidders = _bidders[offerId];
        uint256 len = bidders.length;
        Bid[] memory result = new Bid[](len);
        for (uint256 i = 0; i < len; i++) {
            result[i] = _bids[offerId][bidders[i]];
        }
        return result;
    }

    function getPlayerOffer(uint256 playerId) external view returns (uint256) {
        return _playerOffer[playerId];
    }

    // I forward getPlayerDeal to DealEscrow — ReleaseEscrow calls this to block
    // release clause triggers when a deal is already live for that player
    function getPlayerDeal(uint256 playerId) external view returns (uint256) {
        return dealEscrow.getPlayerDeal(playerId);
    }

    function getTransferBan(address club) external view returns (TransferBan memory) {
        return _transferBans[club];
    }

    function isTokenApproved(address token) external view returns (bool) {
        return _approvedTokens[token];
    }

    function getApprovedTokens() external view returns (address[] memory) {
        return _approvedTokenList;
    }

    function totalOffers() external view returns (uint256) {
        return _offerIdCounter;
    }
}
