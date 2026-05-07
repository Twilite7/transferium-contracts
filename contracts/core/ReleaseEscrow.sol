// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IPlayerRegistry.sol";
import "../interfaces/ITransferWindow.sol";
import "../interfaces/ITransferEscrow.sol";

/**
 * @title ReleaseEscrow
 * @author Transferium Protocol
 * @notice Handles release clause triggers separately from the main transfer flow.
 *
 * @dev Kept as a separate UUPS contract to stay within the 24KB deployment limit.
 *      Release clauses bypass the offer/bid/negotiation flow entirely — a buying
 *      club deposits the exact release clause amount and the player consents.
 *
 *      Release Clause Flow:
 *        AWAITING_PLAYER_CONSENT -> AWAITING_TRANSFER_MEDICAL ->
 *        PENDING_WINDOW (if window closed) -> COMPLETED
 *
 * Security notes:
 *      - Buying club bears timing risk if window is closed at medical completion
 *      - Funds locked immediately at trigger — full refund only if player declines
 *        or medical fails
 *      - Protocol fee deducted at settlement
 *      - UUPS upgrade protected by DEFAULT_ADMIN_ROLE
 */
contract ReleaseEscrow is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // ─── Reentrancy Guard ─────────────────────────────────────────────────────
    // I implement this directly — OZ v5 removed ReentrancyGuardUpgradeable
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

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant CLUB_ROLE  = keccak256("CLUB_ROLE");

    // ─── Constants ────────────────────────────────────────────────────────────

    uint256 public constant MAX_PROTOCOL_FEE_BPS = 200;  // 2% hard cap
    uint256 public constant BPS_DENOMINATOR      = 10_000;
    uint256 public constant MIN_CONSENT_WINDOW   = 1 hours;
    uint256 public constant MIN_MEDICAL_WINDOW   = 1 hours;

    // ─── Enums ────────────────────────────────────────────────────────────────

    enum ReleaseState {
        NONE,
        AWAITING_PLAYER_CONSENT,
        AWAITING_TRANSFER_MEDICAL,
        PENDING_WINDOW,   // window was closed at medical completion — waiting
        COMPLETED,
        CANCELLED
    }

    enum MedicalOutcome { NONE, PASSED, FAILED, CONCERN }

    // ─── Structs ──────────────────────────────────────────────────────────────

    struct ReleaseDeal {
        uint256        playerId;
        address        buyingClub;
        address        paymentToken;
        uint256        amount;
        ReleaseState   state;
        uint256        stateDeadline;
        bytes32        medicalHash;
        MedicalOutcome medicalOutcome;
        uint256        createdAt;
    }

    // ─── State Variables ──────────────────────────────────────────────────────

    uint256 private _releaseIdCounter;

    IPlayerRegistry  public playerRegistry;
    ITransferWindow  public transferWindow;
    ITransferEscrow  public transferEscrow;

    // I store treasury separately — cannot be zero after init
    address  public treasury;
    uint256  public protocolFeeBps;
    uint256  public consentWindow;
    uint256  public medicalWindow;

    mapping(uint256 => ReleaseDeal) private _releases;
    // I track one active release per player — no parallel release triggers
    mapping(uint256 => uint256)     private _playerRelease;

    // I use pull withdrawal for all payouts — no direct transfers
    mapping(address => mapping(address => uint256)) private _claimable;

    // I whitelist tokens to prevent fee-on-transfer or rebasing token exploits
    mapping(address => bool) private _approvedTokens;

    // I track transfer bans — banned clubs cannot trigger release clauses
    mapping(address => bool) private _transferBanned;

    // ─── Events ───────────────────────────────────────────────────────────────

    event ReleaseTriggered(uint256 indexed releaseId, uint256 indexed playerId, address indexed buyingClub, uint256 amount);
    event ReleaseCompleted(uint256 indexed releaseId, uint256 indexed playerId, address indexed newClub);
    event ReleaseCancelled(uint256 indexed releaseId, string reason);
    event PlayerConsented(uint256 indexed releaseId, uint256 indexed playerId);
    event PlayerDeclined(uint256 indexed releaseId, uint256 indexed playerId);
    event MedicalSubmitted(uint256 indexed releaseId, MedicalOutcome outcome);
    event FundsClaimed(address indexed recipient, address indexed token, uint256 amount);
    event TreasuryUpdated(address indexed newTreasury);
    event ProtocolFeeUpdated(uint256 newBps);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error InvalidAddress();
    error InvalidAmount();
    error TokenNotApproved();
    error WrongReleaseState();
    error NotBuyingClub();
    error NotPlayerWallet();
    error PlayerWalletNotSet();
    error NoReleaseClauseSet();
    error PlayerHasActiveOffer();
    error PlayerHasActiveDeal();
    error PlayerHasActiveRelease();
    error CannotBuyOwnPlayer();
    error ClubTransferBanned();
    error ReleaseNotFound();
    error ConsentWindowExpired();
    error MedicalWindowExpired();
    error MedicalAlreadySubmitted();
    error TransferWindowClosed();
    error NothingToClaim();
    error ProtocolFeeTooHigh();
    error TimerTooShort();
    error ReentrantCall();

    // ─── Initializer ──────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _playerRegistry,
        address _transferWindow,
        address _transferEscrow,
        address _treasury,
        address _admin
    ) external initializer {
        if (_playerRegistry  == address(0)) revert InvalidAddress();
        if (_transferWindow  == address(0)) revert InvalidAddress();
        if (_transferEscrow  == address(0)) revert InvalidAddress();
        if (_treasury        == address(0)) revert InvalidAddress();
        if (_admin           == address(0)) revert InvalidAddress();

        __AccessControl_init();
        __Pausable_init();

        _reentrancyStatus = _NOT_ENTERED;

        playerRegistry = IPlayerRegistry(_playerRegistry);
        transferWindow = ITransferWindow(_transferWindow);
        transferEscrow = ITransferEscrow(_transferEscrow);
        treasury       = _treasury;

        consentWindow  = 72 hours;
        medicalWindow  = 72 hours;
        protocolFeeBps = 50; // 0.5% default

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE,         _admin);
    }

    // ─── UUPS ─────────────────────────────────────────────────────────────────

    function _authorizeUpgrade(address)
        internal
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {}

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier releaseExists(uint256 releaseId) {
        if (_releases[releaseId].createdAt == 0) revert ReleaseNotFound();
        _;
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function setTreasury(address _treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_treasury == address(0)) revert InvalidAddress();
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    function setProtocolFee(uint256 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > MAX_PROTOCOL_FEE_BPS) revert ProtocolFeeTooHigh();
        protocolFeeBps = bps;
        emit ProtocolFeeUpdated(bps);
    }

    function setConsentWindow(uint256 duration) external onlyRole(ADMIN_ROLE) {
        if (duration < MIN_CONSENT_WINDOW) revert TimerTooShort();
        consentWindow = duration;
    }

    function setMedicalWindow(uint256 duration) external onlyRole(ADMIN_ROLE) {
        if (duration < MIN_MEDICAL_WINDOW) revert TimerTooShort();
        medicalWindow = duration;
    }

    function approveToken(address token) external onlyRole(ADMIN_ROLE) {
        if (token == address(0)) revert InvalidAddress();
        _approvedTokens[token] = true;
    }

    function revokeToken(address token) external onlyRole(ADMIN_ROLE) {
        _approvedTokens[token] = false;
    }

    function setBan(address club, bool banned) external onlyRole(ADMIN_ROLE) {
        _transferBanned[club] = banned;
    }

    function pause()   external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    // ─── Release Clause Functions ─────────────────────────────────────────────

    /**
     * @notice Trigger a player's release clause.
     * @dev Buying club deposits exact release clause amount immediately.
     *      Transfer window need not be open — NFT transfer waits for next window.
     *      Timing risk belongs to the buying club — no expiry on PENDING_WINDOW.
     */
    function triggerReleaseClause(
        uint256 playerId,
        address paymentToken
    )
        external
        whenNotPaused
        nonReentrant
        returns (uint256 releaseId)
    {
        if (!_approvedTokens[paymentToken])    revert TokenNotApproved();
        if (_transferBanned[msg.sender])        revert ClubTransferBanned();
        if (_playerRelease[playerId] != 0)      revert PlayerHasActiveRelease();

        // I check main transfer contract for conflicting active processes
        // A player cannot have a release triggered while an offer or deal is live
        if (transferEscrow.getPlayerOffer(playerId) != 0) revert PlayerHasActiveOffer();
        if (transferEscrow.getPlayerDeal(playerId)  != 0) revert PlayerHasActiveDeal();

        IPlayerRegistry.Player memory player = playerRegistry.getPlayer(playerId);
        if (player.releaseClause == 0)         revert NoReleaseClauseSet();
        if (player.playerWallet == address(0)) revert PlayerWalletNotSet();

        address currentClub = playerRegistry.currentClub(playerId);
        if (currentClub == msg.sender) revert CannotBuyOwnPlayer();

        // I lock full release clause amount immediately — no partial deposits
        IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), player.releaseClause);

        _releaseIdCounter++;
        releaseId = _releaseIdCounter;

        _releases[releaseId] = ReleaseDeal({
            playerId:       playerId,
            buyingClub:     msg.sender,
            paymentToken:   paymentToken,
            amount:         player.releaseClause,
            state:          ReleaseState.AWAITING_PLAYER_CONSENT,
            stateDeadline:  block.timestamp + consentWindow,
            medicalHash:    bytes32(0),
            medicalOutcome: MedicalOutcome.NONE,
            createdAt:      block.timestamp
        });

        _playerRelease[playerId] = releaseId;

        emit ReleaseTriggered(releaseId, playerId, msg.sender, player.releaseClause);
    }

    /**
     * @notice Player consents to move — advances to medical stage.
     */
    function consentToRelease(uint256 releaseId)
        external
        whenNotPaused
        nonReentrant
        releaseExists(releaseId)
    {
        ReleaseDeal storage rel = _releases[releaseId];
        if (rel.state != ReleaseState.AWAITING_PLAYER_CONSENT) revert WrongReleaseState();
        if (block.timestamp > rel.stateDeadline)               revert ConsentWindowExpired();

        IPlayerRegistry.Player memory player = playerRegistry.getPlayer(rel.playerId);
        if (player.playerWallet == address(0)) revert PlayerWalletNotSet();
        if (player.playerWallet != msg.sender) revert NotPlayerWallet();

        rel.state         = ReleaseState.AWAITING_TRANSFER_MEDICAL;
        rel.stateDeadline = block.timestamp + medicalWindow;

        emit PlayerConsented(releaseId, rel.playerId);
    }

    /**
     * @notice Player declines — full refund to buying club, release cancelled.
     */
    function declineRelease(uint256 releaseId)
        external
        whenNotPaused
        nonReentrant
        releaseExists(releaseId)
    {
        ReleaseDeal storage rel = _releases[releaseId];
        if (rel.state != ReleaseState.AWAITING_PLAYER_CONSENT) revert WrongReleaseState();

        IPlayerRegistry.Player memory player = playerRegistry.getPlayer(rel.playerId);
        if (player.playerWallet == address(0)) revert PlayerWalletNotSet();
        if (player.playerWallet != msg.sender) revert NotPlayerWallet();

        // I credit full refund before changing state — CEI pattern
        _claimable[rel.buyingClub][rel.paymentToken] += rel.amount;
        rel.state = ReleaseState.CANCELLED;
        _playerRelease[rel.playerId] = 0;

        emit PlayerDeclined(releaseId, rel.playerId);
        emit ReleaseCancelled(releaseId, "Player declined release clause");
    }

    /**
     * @notice Buying club submits medical result.
     * @dev CONCERN treated same as PASSED — release amount is fixed, no renegotiation.
     *      If window is closed at medical completion, deal enters PENDING_WINDOW.
     *      Timing risk belongs to the buying club.
     */
    function submitReleaseMedical(
        uint256        releaseId,
        MedicalOutcome outcome,
        bytes32        medicalHash
    )
        external
        whenNotPaused
        nonReentrant
        releaseExists(releaseId)
    {
        ReleaseDeal storage rel = _releases[releaseId];
        if (rel.state != ReleaseState.AWAITING_TRANSFER_MEDICAL) revert WrongReleaseState();
        if (rel.buyingClub != msg.sender)         revert NotBuyingClub();
        if (block.timestamp > rel.stateDeadline)  revert MedicalWindowExpired();
        if (rel.medicalHash != bytes32(0))         revert MedicalAlreadySubmitted();
        if (medicalHash == bytes32(0))             revert InvalidAddress();
        if (outcome == MedicalOutcome.NONE)        revert InvalidAmount();

        rel.medicalHash    = medicalHash;
        rel.medicalOutcome = outcome;

        emit MedicalSubmitted(releaseId, outcome);

        if (outcome == MedicalOutcome.FAILED) {
            // I refund buying club — medical failure, no penalty on release clauses
            _claimable[rel.buyingClub][rel.paymentToken] += rel.amount;
            rel.state = ReleaseState.CANCELLED;
            _playerRelease[rel.playerId] = 0;
            emit ReleaseCancelled(releaseId, "Medical failed");
        } else {
            // PASSED or CONCERN — release amount is fixed, no renegotiation allowed
            // I emit for CONCERN so selling club knows a flag was raised
            if (outcome == MedicalOutcome.CONCERN) {
                emit MedicalSubmitted(releaseId, MedicalOutcome.CONCERN);
            }
            if (transferWindow.isWindowOpen()) {
                _settleRelease(releaseId);
            } else {
                // I park the deal — buying club calls executeRelease when window opens
                // Timing risk is explicitly on the buying club per protocol design
                rel.state         = ReleaseState.PENDING_WINDOW;
                rel.stateDeadline = 0; // no expiry — buying club chose to trigger
            }
        }
    }

    /**
     * @notice Execute a pending release when the transfer window opens.
     * @dev Only the buying club can call — they bear the timing risk.
     */
    function executeRelease(uint256 releaseId)
        external
        whenNotPaused
        nonReentrant
        releaseExists(releaseId)
    {
        ReleaseDeal storage rel = _releases[releaseId];
        if (rel.state != ReleaseState.PENDING_WINDOW) revert WrongReleaseState();
        if (rel.buyingClub != msg.sender)             revert NotBuyingClub();
        if (!transferWindow.isWindowOpen())            revert TransferWindowClosed();

        _settleRelease(releaseId);
    }

    /**
     * @notice Process expired consent window — refund buying club.
     * @dev Anyone can call to unstick a stuck release.
     */
    function processExpiry(uint256 releaseId)
        external
        nonReentrant
        releaseExists(releaseId)
    {
        ReleaseDeal storage rel = _releases[releaseId];
        if (rel.stateDeadline == 0)               revert WrongReleaseState();
        if (block.timestamp <= rel.stateDeadline) revert WrongReleaseState();
        if (rel.state != ReleaseState.AWAITING_PLAYER_CONSENT &&
            rel.state != ReleaseState.AWAITING_TRANSFER_MEDICAL) revert WrongReleaseState();

        // I refund buying club on expiry — no penalty, time ran out
        _claimable[rel.buyingClub][rel.paymentToken] += rel.amount;
        rel.state = ReleaseState.CANCELLED;
        _playerRelease[rel.playerId] = 0;

        emit ReleaseCancelled(releaseId, "Release window expired");
    }

    // ─── Pull Withdrawal ──────────────────────────────────────────────────────

    function withdrawClaimable(address token)
        external
        nonReentrant
    {
        // I do not gate on _approvedTokens — revoked tokens must still be withdrawable
        uint256 amount = _claimable[msg.sender][token];
        if (amount == 0) revert NothingToClaim();
        // I zero before transfer — prevents reentrancy on the claimable balance
        _claimable[msg.sender][token] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit FundsClaimed(msg.sender, token, amount);
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    /**
     * @notice Settle a completed release — distribute fees and transfer NFT.
     * @dev All state changes before external call — strict CEI pattern.
     */
    function _settleRelease(uint256 releaseId) internal {
        ReleaseDeal storage rel = _releases[releaseId];
        rel.state = ReleaseState.COMPLETED;
        _playerRelease[rel.playerId] = 0;

        address sellingClub = playerRegistry.currentClub(rel.playerId);
        uint256 amount    = rel.amount;
        uint256 remaining = amount;

        // I deduct protocol fee first
        if (protocolFeeBps > 0 && treasury != address(0)) {
            uint256 fee = (amount * protocolFeeBps) / BPS_DENOMINATOR;
            remaining  -= fee;
            _claimable[treasury][rel.paymentToken] += fee;
        }

        // Sell-on clause note: Player struct does not store sell-on terms.
        // Sell-on rights on release clause triggers must be enforced off-chain.
        // This mirrors FIFA rules — release clauses override most contractual
        // protections unless explicitly drafted otherwise in the employment contract.

        // I send remainder to the selling club
        _claimable[sellingClub][rel.paymentToken] += remaining;

        // I transfer NFT last — all state and claimable updates done before external call
        playerRegistry.escrowTransfer(rel.playerId, sellingClub, rel.buyingClub);

        emit ReleaseCompleted(releaseId, rel.playerId, rel.buyingClub);
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    function getRelease(uint256 releaseId)
        external view releaseExists(releaseId) returns (ReleaseDeal memory) {
        return _releases[releaseId];
    }

    function getPlayerRelease(uint256 playerId) external view returns (uint256) {
        return _playerRelease[playerId];
    }

    function getClaimable(address account, address token)
        external view returns (uint256) {
        return _claimable[account][token];
    }

    function isTokenApproved(address token) external view returns (bool) {
        return _approvedTokens[token];
    }

    function totalReleases() external view returns (uint256) {
        return _releaseIdCounter;
    }
}
