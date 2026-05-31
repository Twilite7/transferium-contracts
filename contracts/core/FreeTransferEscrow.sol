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
import "../interfaces/ITransferEscrow.sol";

/**
 * @title FreeTransferEscrow
 * @author Transferium Protocol
 * @notice Handles free transfers — players whose contracts have expired.
 *
 * @dev Flow:
 *   RELEASED -> PRE_CONTRACT_PROPOSED -> PRE_CONTRACT_SIGNED ->
 *   (lockDeposit) -> AWAITING_MEDICAL -> COMPLETED
 *
 * Mutual termination:
 *   Club proposeMutualTermination() -> player confirmMutualTermination() ->
 *   settlement paid -> player RELEASED
 *
 * Key security properties:
 *   - Medical cannot be submitted before deposit is locked (prevents undercollateralisation)
 *   - cancelExpiredDeposit() unblocks player if buying club never locks deposit
 *   - Pull-payment pattern for all outgoing funds
 *   - 40-slot storage gap for upgrade safety
 */
contract FreeTransferEscrow is
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

    // ─── Roles ────────────────────────────────────────────────────────────────

    bytes32 public constant ADMIN_ROLE    = keccak256("ADMIN_ROLE");
    bytes32 public constant CLUB_ROLE     = keccak256("CLUB_ROLE");
    bytes32 public constant LEAGUE_ROLE   = keccak256("LEAGUE_ROLE");

    // ─── Constants ────────────────────────────────────────────────────────────

    uint256 public constant BPS_DENOMINATOR     = 10_000;
    uint256 public constant MAX_AGENT_BPS       = 300;
    uint256 public constant MIN_CONSENT_WINDOW  = 1 hours;
    uint256 public constant MIN_MEDICAL_WINDOW  = 1 hours;
    uint256 public constant PRE_CONTRACT_WINDOW = 180 days;
    uint256 public constant DEFAULT_DEPOSIT_BPS = 1000;
    uint256 public constant TERMINATION_EXPIRY  = 30 days;

    // ─── Enums ────────────────────────────────────────────────────────────────

    enum FreeTransferState {
        NONE,
        RELEASED,
        PRE_CONTRACT_PROPOSED,
        PRE_CONTRACT_SIGNED,
        AWAITING_MEDICAL,
        PENDING_WINDOW,
        COMPLETED,
        CANCELLED
    }

    enum MedicalOutcome { NONE, PASSED, FAILED, CONCERN }

    // ─── Structs ──────────────────────────────────────────────────────────────

    struct FreeTransfer {
        uint256           playerId;
        address           currentClub;
        address           buyingClub;
        address           paymentToken;
        uint256           signingBonus;
        uint256           buyerAgentBps;
        address           buyerAgent;
        uint256           sellerAgentBps;
        address           sellerAgent;
        uint256           deposit;
        bool              depositLocked;   // true once lockDeposit() executes transfer
        FreeTransferState state;
        uint256           stateDeadline;   // 0 once deposit locked (no further deadline)
        bytes32           medicalHash;
        MedicalOutcome    medicalOutcome;
        uint256           createdAt;
    }

    struct MutualTermination {
        uint256 playerId;
        address club;
        address paymentToken;
        uint256 settlementAmount;
        uint256 proposedAt;
        bool    exists;
    }

    // ─── State ────────────────────────────────────────────────────────────────

    uint256 private _ftIdCounter;

    IPlayerRegistry  public playerRegistry;
    IAddressRegistry public addressRegistry;
    ITransferEscrow  public transferEscrow;

    uint256 public consentWindow;
    uint256 public medicalWindow;
    uint256 public depositBps;

    // playerId => ftId (active free transfer process)
    mapping(uint256 => uint256)           private _playerFT;
    // playerId => true if player is a free agent (in vault)
    mapping(uint256 => bool)              private _freeAgentStatus;
    // ftId => FreeTransfer
    mapping(uint256 => FreeTransfer)      private _fts;
    // playerId => competing proposals: buyingClub => ftId
    mapping(uint256 => mapping(address => uint256)) private _proposals;
    // playerId => list of proposing clubs
    mapping(uint256 => address[])         private _proposers;
    // playerId => active pre-contract ftId (only one at a time)
    mapping(uint256 => uint256)           private _activePreContract;
    // mutual termination proposals
    mapping(uint256 => MutualTermination) private _terminations;

    mapping(address => mapping(address => uint256)) private _claimable;
    mapping(address => bool)  private _approvedTokens;
    address[]                 private _approvedTokenList;

    // ─── Storage gap ──────────────────────────────────────────────────────────
    uint256[40] private __gap;

    // ─── Events ───────────────────────────────────────────────────────────────

    event PlayerReleased(uint256 indexed playerId, address indexed fromClub);
    event MutualTerminationProposed(uint256 indexed playerId, address indexed club, uint256 settlementAmount);
    event MutualTerminationConfirmed(uint256 indexed playerId);
    event PreContractProposed(uint256 indexed ftId, uint256 indexed playerId, address indexed buyingClub);
    event PreContractSigned(uint256 indexed ftId, uint256 indexed playerId, address indexed buyingClub, uint256 deposit);
    event DepositLocked(uint256 indexed ftId, uint256 amount);
    event PreContractCancelled(uint256 indexed ftId, string reason);
    event MedicalSubmitted(uint256 indexed ftId, MedicalOutcome outcome);
    event FreeTransferCompleted(uint256 indexed ftId, uint256 indexed playerId, address indexed newClub);
    event FundsClaimed(address indexed recipient, address indexed token, uint256 amount);
    event TokenApproved(address indexed token);
    event TokenRevoked(address indexed token);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error ReentrantCall();
    error InvalidAddress();
    error NothingToWithdraw();
    error InsufficientProtocolBalance(uint256 requested, uint256 available);
    error InvalidAmount();
    error TokenNotApproved();
    error TokenAlreadyApproved();
    error TokenNotInList();
    error NotPlayerWallet();
    error PlayerWalletNotSet();
    error NotCurrentClub();
    error NotBuyingClub();
    error PlayerNotFreeAgent();
    error PlayerAlreadyFreeAgent();
    error ContractNotExpired();
    error TooEarlyForPreContract();
    error AlreadyProposed();
    error PreContractAlreadyActive();
    error NoActivePreContract();
    error WrongState();
    error ConsentWindowExpired();
    error MedicalWindowExpired();
    error MedicalAlreadySubmitted();
    error TransferWindowClosed();
    error NothingToClaim();
    error TimerTooShort();
    error TerminationNotProposed();
    error TerminationAlreadyProposed();
    error CannotConfirmOwnProposal();
    error PlayerHasActiveProcess();
    error DepositNotLocked();
    error DepositAlreadyLocked();

    // ─── Initializer ──────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(
        address _playerRegistry,
        address _addressRegistry,
        address _transferEscrow,
        address _treasury,
        address _admin
    ) external initializer {
        if (_playerRegistry == address(0)) revert InvalidAddress();
        if (_addressRegistry == address(0)) revert InvalidAddress();
        if (_transferEscrow  == address(0)) revert InvalidAddress();
        if (_treasury        == address(0)) revert InvalidAddress();
        if (_admin           == address(0)) revert InvalidAddress();

        __AccessControl_init();
        __Pausable_init();
        _reentrancyStatus = _NOT_ENTERED;

        playerRegistry  = IPlayerRegistry(_playerRegistry);
        addressRegistry = IAddressRegistry(_addressRegistry);
        transferEscrow  = ITransferEscrow(_transferEscrow);
        treasury        = _treasury;

        consentWindow  = 14 days;
        medicalWindow  = 72 hours;
        protocolFeeBps = 50;
        depositBps     = DEFAULT_DEPOSIT_BPS;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE,         _admin);
        _grantRole(LEAGUE_ROLE,        _admin);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

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

    function setConsentWindow(uint256 d) external onlyRole(ADMIN_ROLE) {
        if (d < MIN_CONSENT_WINDOW) revert TimerTooShort();
        consentWindow = d;
    }

    function setMedicalWindow(uint256 d) external onlyRole(ADMIN_ROLE) {
        if (d < MIN_MEDICAL_WINDOW) revert TimerTooShort();
        medicalWindow = d;
    }

    function setDepositBps(uint256 bps) external onlyRole(ADMIN_ROLE) {
        if (bps > BPS_DENOMINATOR) revert InvalidAmount();
        depositBps = bps;
    }

    function approveToken(address token) external onlyRole(ADMIN_ROLE) {
        if (token == address(0)) revert InvalidAddress();
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

    function pause()   external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    // ─── Mutual Termination ───────────────────────────────────────────────────

    /**
     * @notice Club proposes mutual termination. Settlement locked immediately.
     */
    function proposeMutualTermination(
        uint256 playerId,
        address paymentToken,
        uint256 settlementAmount
    )
        external whenNotPaused nonReentrant onlyRole(CLUB_ROLE)
    {
        if (!_approvedTokens[paymentToken])                      revert TokenNotApproved();
        if (playerRegistry.currentClub(playerId) != msg.sender) revert NotCurrentClub();
        if (_freeAgentStatus[playerId])                          revert PlayerAlreadyFreeAgent();
        if (_terminations[playerId].exists)                      revert TerminationAlreadyProposed();
        if (_playerFT[playerId] != 0)                            revert PlayerHasActiveProcess();

        IPlayerRegistry.Player memory player = playerRegistry.getPlayer(playerId);
        if (player.playerWallet == address(0)) revert PlayerWalletNotSet();

        // I lock settlement funds immediately — club cannot withdraw without player declining
        if (settlementAmount > 0) {
            IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), settlementAmount);
        }

        _terminations[playerId] = MutualTermination({
            playerId:         playerId,
            club:             msg.sender,
            paymentToken:     paymentToken,
            settlementAmount: settlementAmount,
            proposedAt:       block.timestamp,
            exists:           true
        });

        emit MutualTerminationProposed(playerId, msg.sender, settlementAmount);
    }

    /**
     * @notice Player confirms mutual termination — becomes a free agent.
     */
    function confirmMutualTermination(uint256 playerId)
        external whenNotPaused nonReentrant
    {
        MutualTermination storage t = _terminations[playerId];
        if (!t.exists) revert TerminationNotProposed();
        if (block.timestamp > t.proposedAt + TERMINATION_EXPIRY) revert ConsentWindowExpired();

        IPlayerRegistry.Player memory player = playerRegistry.getPlayer(playerId);
        if (player.playerWallet == address(0)) revert PlayerWalletNotSet();
        if (player.playerWallet != msg.sender) revert NotPlayerWallet();

        address club       = t.club;
        address token      = t.paymentToken;
        uint256 settlement = t.settlementAmount;

        delete _terminations[playerId];

        if (settlement > 0) {
            _claimable[player.playerWallet][token] += settlement;
        }

        _freeAgentStatus[playerId] = true;
        playerRegistry.escrowTransfer(playerId, club, address(this));

        emit MutualTerminationConfirmed(playerId);
        emit PlayerReleased(playerId, club);
    }

    /**
     * @notice Club withdraws termination proposal — refunded.
     */
    function withdrawMutualTermination(uint256 playerId)
        external nonReentrant onlyRole(CLUB_ROLE)
    {
        MutualTermination storage t = _terminations[playerId];
        if (!t.exists)            revert TerminationNotProposed();
        if (t.club != msg.sender) revert NotCurrentClub();

        uint256 settlement = t.settlementAmount;
        address token      = t.paymentToken;
        delete _terminations[playerId];

        if (settlement > 0) {
            _claimable[msg.sender][token] += settlement;
        }
    }

    /**
     * @notice Release a player whose contract has expired.
     * @dev Restricted to the player's current club or LEAGUE_ROLE —
     *      prevents third-party griefing of clubs not yet ready to release.
     */
    function releaseExpiredContract(uint256 playerId)
        external whenNotPaused nonReentrant
    {
        if (_freeAgentStatus[playerId]) revert PlayerAlreadyFreeAgent();
        if (_playerFT[playerId] != 0)   revert PlayerHasActiveProcess();

        address club = playerRegistry.currentClub(playerId);
        // I restrict to the owning club or league — any-club griefing risk otherwise
        bool authorised = (msg.sender == club && hasRole(CLUB_ROLE, msg.sender))
                          || hasRole(LEAGUE_ROLE, msg.sender);
        if (!authorised) revert NotCurrentClub();

        IPlayerRegistry.Player memory player = playerRegistry.getPlayer(playerId);
        if (block.timestamp < player.contractExpiry) revert ContractNotExpired();

        _freeAgentStatus[playerId] = true;
        playerRegistry.escrowTransfer(playerId, club, address(this));

        emit PlayerReleased(playerId, club);
    }

    // ─── Pre-Contract ─────────────────────────────────────────────────────────

    /**
     * @notice Buying club proposes a pre-contract. Multiple clubs can propose.
     */
    function proposePreContract(
        uint256 playerId,
        address paymentToken,
        uint256 signingBonus,
        uint256 buyerAgentBps,
        address buyerAgent,
        uint256 sellerAgentBps,
        address sellerAgent
    )
        external whenNotPaused nonReentrant onlyRole(CLUB_ROLE)
    {
        if (!_approvedTokens[paymentToken])           revert TokenNotApproved();
        if (_proposals[playerId][msg.sender] != 0)    revert AlreadyProposed();

        IPlayerRegistry.Player memory player = playerRegistry.getPlayer(playerId);
        if (player.playerWallet == address(0))        revert PlayerWalletNotSet();

        bool isFreeAgent = _freeAgentStatus[playerId];
        bool nearExpiry  = block.timestamp >= player.contractExpiry - PRE_CONTRACT_WINDOW;
        if (!isFreeAgent && !nearExpiry)              revert TooEarlyForPreContract();

        if (buyerAgentBps  > MAX_AGENT_BPS)           revert InvalidAmount();
        if (buyerAgentBps  > 0 && buyerAgent == address(0))  revert InvalidAddress();
        if (sellerAgentBps > MAX_AGENT_BPS)           revert InvalidAmount();
        if (sellerAgentBps > 0 && sellerAgent == address(0)) revert InvalidAddress();

        _ftIdCounter++;
        uint256 ftId = _ftIdCounter;

        _fts[ftId] = FreeTransfer({
            playerId:       playerId,
            currentClub:    isFreeAgent ? address(0) : playerRegistry.currentClub(playerId),
            buyingClub:     msg.sender,
            paymentToken:   paymentToken,
            signingBonus:   signingBonus,
            buyerAgentBps:  buyerAgentBps,
            buyerAgent:     buyerAgent,
            sellerAgentBps: sellerAgentBps,
            sellerAgent:    sellerAgent,
            deposit:        0,
            depositLocked:  false,
            state:          FreeTransferState.PRE_CONTRACT_PROPOSED,
            stateDeadline:  block.timestamp + consentWindow,
            medicalHash:    bytes32(0),
            medicalOutcome: MedicalOutcome.NONE,
            createdAt:      block.timestamp
        });

        _proposals[playerId][msg.sender] = ftId;
        _proposers[playerId].push(msg.sender);

        emit PreContractProposed(ftId, playerId, msg.sender);
    }

    /**
     * @notice Player signs a pre-contract with a specific buying club.
     */
    function signPreContract(uint256 ftId)
        external whenNotPaused nonReentrant
    {
        FreeTransfer storage ft = _fts[ftId];
        if (ft.createdAt == 0)                                   revert WrongState();
        if (ft.state != FreeTransferState.PRE_CONTRACT_PROPOSED) revert WrongState();
        if (block.timestamp > ft.stateDeadline)                  revert ConsentWindowExpired();

        IPlayerRegistry.Player memory player = playerRegistry.getPlayer(ft.playerId);
        if (player.playerWallet == address(0)) revert PlayerWalletNotSet();
        if (player.playerWallet != msg.sender) revert NotPlayerWallet();

        if (_activePreContract[ft.playerId] != 0) revert PreContractAlreadyActive();

        uint256 deposit = ft.signingBonus > 0
            ? (ft.signingBonus * depositBps) / BPS_DENOMINATOR
            : 0;

        // I mark state before any external interactions — CEI
        ft.state         = FreeTransferState.PRE_CONTRACT_SIGNED;
        ft.deposit       = deposit;
        ft.stateDeadline = block.timestamp + consentWindow; // buying club must lock deposit by this time

        _activePreContract[ft.playerId] = ftId;
        _playerFT[ft.playerId]          = ftId;

        emit PreContractSigned(ftId, ft.playerId, ft.buyingClub, deposit);
    }

    /**
     * @notice Buying club locks deposit after player signs.
     * @dev Must be called before stateDeadline. Once locked, stateDeadline is cleared.
     */
    function lockDeposit(uint256 ftId)
        external whenNotPaused nonReentrant onlyRole(CLUB_ROLE)
    {
        FreeTransfer storage ft = _fts[ftId];
        if (ft.createdAt == 0)                                 revert WrongState();
        if (ft.state != FreeTransferState.PRE_CONTRACT_SIGNED) revert WrongState();
        if (ft.buyingClub != msg.sender)                       revert NotBuyingClub();
        if (block.timestamp > ft.stateDeadline)                revert ConsentWindowExpired();
        if (ft.depositLocked)                                  revert DepositAlreadyLocked();

        // I clear the deadline after locking — no further time limit on signed pre-contract
        ft.stateDeadline = 0;

        if (ft.deposit == 0) {
            ft.depositLocked = true;
            return;
        }

        // Mark locked BEFORE pulling funds — if transfer reverts, whole tx reverts
        ft.depositLocked = true;
        IERC20(ft.paymentToken).safeTransferFrom(msg.sender, address(this), ft.deposit);

        emit DepositLocked(ftId, ft.deposit);
    }

    /**
     * @notice Cancel an expired deposit commitment.
     * @dev Callable by anyone once stateDeadline passes without lockDeposit.
     *      No token movement — deposit was never transferred.
     */
    function cancelExpiredDeposit(uint256 ftId) external nonReentrant {
        FreeTransfer storage ft = _fts[ftId];
        if (ft.createdAt == 0)                                 revert WrongState();
        if (ft.state != FreeTransferState.PRE_CONTRACT_SIGNED) revert WrongState();
        if (ft.depositLocked)                                  revert DepositAlreadyLocked();
        if (ft.stateDeadline == 0)                             revert WrongState(); // no deadline = deposit locked
        if (block.timestamp <= ft.stateDeadline)               revert ConsentWindowExpired();

        // I clear the active pre-contract so the player can sign with another club
        _proposals[ft.playerId][ft.buyingClub] = 0;
        _activePreContract[ft.playerId] = 0;
        _playerFT[ft.playerId]          = 0;
        ft.state = FreeTransferState.CANCELLED;

        emit PreContractCancelled(ftId, "Deposit not locked in time");
    }

    /**
     * @notice Buying club withdraws from a pre-contract.
     * @dev Before signing: clean cancel. After signing: deposit forfeited to player
     *      (only if deposit was actually locked — otherwise no forfeiture).
     */
    function withdrawPreContract(uint256 ftId)
        external whenNotPaused nonReentrant onlyRole(CLUB_ROLE)
    {
        FreeTransfer storage ft = _fts[ftId];
        if (ft.createdAt == 0)           revert WrongState();
        if (ft.buyingClub != msg.sender) revert NotBuyingClub();

        if (ft.state == FreeTransferState.PRE_CONTRACT_PROPOSED) {
            ft.state = FreeTransferState.CANCELLED;
            _proposals[ft.playerId][msg.sender] = 0;
            emit PreContractCancelled(ftId, "Club withdrew before signing");

        } else if (ft.state == FreeTransferState.PRE_CONTRACT_SIGNED) {
            // I only forfeit if the deposit was actually locked
            if (ft.depositLocked && ft.deposit > 0) {
                IPlayerRegistry.Player memory player = playerRegistry.getPlayer(ft.playerId);
                if (player.playerWallet != address(0)) {
                    _claimable[player.playerWallet][ft.paymentToken] += ft.deposit;
                }
            }
            ft.state = FreeTransferState.CANCELLED;
            _proposals[ft.playerId][msg.sender] = 0;
            _activePreContract[ft.playerId] = 0;
            _playerFT[ft.playerId]          = 0;
            emit PreContractCancelled(ftId,
                ft.depositLocked
                    ? "Club withdrew after signing - deposit forfeited"
                    : "Club withdrew after signing - deposit not yet locked");
        } else {
            revert WrongState();
        }
    }

    // ─── Medical ──────────────────────────────────────────────────────────────

    /**
     * @notice Buying club submits medical once transfer window opens.
     * @dev Deposit must be locked before medical can be submitted — this
     *      prevents a club from completing the transfer without paying the deposit.
     */
    function submitMedical(
        uint256 ftId,
        MedicalOutcome outcome,
        bytes32 medicalHash
    )
        external whenNotPaused nonReentrant
    {
        FreeTransfer storage ft = _fts[ftId];
        if (ft.createdAt == 0)                                 revert WrongState();
        if (ft.state != FreeTransferState.PRE_CONTRACT_SIGNED) revert WrongState();
        if (ft.buyingClub != msg.sender)                       revert NotBuyingClub();
        // I require deposit locked before medical — prevents undercollateralised settlement
        if (ft.deposit > 0 && !ft.depositLocked)              revert DepositNotLocked();
        if (!ITransferWindow(addressRegistry.get(RegistryKeys.TRANSFER_WINDOW)).isWindowOpen())
            revert TransferWindowClosed();
        if (ft.medicalHash != bytes32(0))                      revert MedicalAlreadySubmitted();
        if (medicalHash == bytes32(0))                         revert InvalidAddress();
        if (outcome == MedicalOutcome.NONE)                    revert InvalidAmount();

        ft.medicalHash    = medicalHash;
        ft.medicalOutcome = outcome;
        ft.state          = FreeTransferState.AWAITING_MEDICAL;

        emit MedicalSubmitted(ftId, outcome);

        if (outcome == MedicalOutcome.FAILED) {
            // I refund the deposit on medical failure — club not at fault
            if (ft.depositLocked && ft.deposit > 0) {
                _claimable[ft.buyingClub][ft.paymentToken] += ft.deposit;
            }
            ft.state = FreeTransferState.CANCELLED;
            _activePreContract[ft.playerId] = 0;
            _playerFT[ft.playerId]          = 0;
            emit PreContractCancelled(ftId, "Medical failed");
        } else {
            _settleFreeTransfer(ftId);
        }
    }

    // ─── Internal Settlement ──────────────────────────────────────────────────

    function _settleFreeTransfer(uint256 ftId) internal {
        FreeTransfer storage ft = _fts[ftId];
        ft.state = FreeTransferState.COMPLETED;
        _activePreContract[ft.playerId] = 0;
        _playerFT[ft.playerId]          = 0;
        _freeAgentStatus[ft.playerId]   = false;

        IPlayerRegistry.Player memory player = playerRegistry.getPlayer(ft.playerId);

        uint256 remaining = ft.signingBonus;

        if (ft.signingBonus > 0 && protocolFeeBps > 0 && treasury != address(0)) {
            uint256 fee = (ft.signingBonus * protocolFeeBps) / BPS_DENOMINATOR;
            remaining  -= fee;
            _claimable[treasury][ft.paymentToken] += fee;
        }

        if (ft.buyerAgentBps > 0 && ft.buyerAgent != address(0)) {
            uint256 agentFee = (ft.signingBonus * ft.buyerAgentBps) / BPS_DENOMINATOR;
            remaining       -= agentFee;
            _claimable[ft.buyerAgent][ft.paymentToken] += agentFee;
        }

        if (ft.sellerAgentBps > 0 && ft.sellerAgent != address(0)) {
            uint256 agentFee = (ft.signingBonus * ft.sellerAgentBps) / BPS_DENOMINATOR;
            remaining       -= agentFee;
            _claimable[ft.sellerAgent][ft.paymentToken] += agentFee;
        }

        // I pull only the portion not already covered by the locked deposit
        if (ft.signingBonus > 0 && player.playerWallet != address(0)) {
            uint256 toPull = ft.signingBonus > ft.deposit ? ft.signingBonus - ft.deposit : 0;
            if (toPull > 0) {
                IERC20(ft.paymentToken).safeTransferFrom(ft.buyingClub, address(this), toPull);
            }
            _claimable[player.playerWallet][ft.paymentToken] += remaining;
        }

        // Transfer NFT from vault (this contract) to buying club
        playerRegistry.escrowTransfer(ft.playerId, address(this), ft.buyingClub);

        emit FreeTransferCompleted(ftId, ft.playerId, ft.buyingClub);
    }

    // ─── Pull Withdrawal ──────────────────────────────────────────────────────

    function withdrawClaimable(address token) external nonReentrant {
        uint256 amt = _claimable[msg.sender][token];
        if (amt == 0) revert NothingToClaim();
        _claimable[msg.sender][token] = 0;
        IERC20(token).safeTransfer(msg.sender, amt);
        emit FundsClaimed(msg.sender, token, amt);
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    function getFT(uint256 ftId) external view returns (FreeTransfer memory) {
        return _fts[ftId];
    }

    function getFreeAgentStatus(uint256 playerId) external view returns (bool) {
        return _freeAgentStatus[playerId];
    }

    function getPlayerFT(uint256 playerId) external view returns (uint256) {
        return _playerFT[playerId];
    }

    function getActivePreContract(uint256 playerId) external view returns (uint256) {
        return _activePreContract[playerId];
    }

    function getProposal(uint256 playerId, address buyingClub) external view returns (uint256) {
        return _proposals[playerId][buyingClub];
    }

    function getTermination(uint256 playerId) external view returns (MutualTermination memory) {
        return _terminations[playerId];
    }

    function getClaimable(address account, address token) external view returns (uint256) {
        return _claimable[account][token];
    }

    function isTokenApproved(address token) external view returns (bool) {
        return _approvedTokens[token];
    }

    function getApprovedTokens() external view returns (address[] memory) {
        return _approvedTokenList;
    }

    function totalFreeTransfers() external view returns (uint256) {
        return _ftIdCounter;
    }
}
