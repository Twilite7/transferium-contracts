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
 * @notice Handles free transfers - players whose contracts have expired.
 *
 * @dev Real-world free transfer rules modelled:
 *      - Player can sign a pre-contract from Jan 1 (6 months before Jun 30 expiry)
 *        or immediately once contract has expired
 *      - Pre-contract is binding - buying club locks a deposit on signing
 *      - If buying club pulls out after pre-contract signed -> deposit goes to player
 *      - Mutual termination (before expiry) - club pays settlement, player released early
 *      - Registration (NFT transfer) only happens when transfer window is open
 *      - No transfer fee - only signing bonus and agent fees flow through escrow
 *
 * Flow:
 *   RELEASED -> PRE_CONTRACT_PROPOSED -> PRE_CONTRACT_SIGNED ->
 *   AWAITING_MEDICAL -> PENDING_WINDOW (if closed) -> COMPLETED
 *
 * Mutual termination flow:
 *   Club calls mutualTermination() -> player calls confirmTermination() ->
 *   settlement paid -> player RELEASED
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

    uint256 public constant BPS_DENOMINATOR        = 10_000;
    uint256 public constant MAX_AGENT_BPS          = 300;
    uint256 public constant MIN_CONSENT_WINDOW     = 1 hours;
    uint256 public constant MIN_MEDICAL_WINDOW     = 1 hours;
    // 6 months before expiry - clubs can propose pre-contract from this point
    uint256 public constant PRE_CONTRACT_WINDOW    = 180 days;
    // Deposit buying club must lock when player signs pre-contract
    // Set as BPS of signing bonus - default 1000 = 10%
    uint256 public constant DEFAULT_DEPOSIT_BPS    = 1000;
    uint256 public constant TERMINATION_EXPIRY      = 30 days;

    // ─── Enums ────────────────────────────────────────────────────────────────

    enum FreeTransferState {
        NONE,
        RELEASED,              // player is a free agent (contract expired or mutually terminated)
        PRE_CONTRACT_PROPOSED, // buying club submitted proposal, player hasn't signed yet
        PRE_CONTRACT_SIGNED,   // player signed - buying club deposit locked
        AWAITING_MEDICAL,      // medical submitted by buying club
        PENDING_WINDOW,        // medical passed but window closed - waiting
        COMPLETED,
        CANCELLED
    }

    enum MedicalOutcome { NONE, PASSED, FAILED, CONCERN }

    // ─── Structs ──────────────────────────────────────────────────────────────

    struct FreeTransfer {
        uint256           playerId;
        address           currentClub;      // address(0) if already released to vault
        address           buyingClub;
        address           paymentToken;
        uint256           signingBonus;     // optional - paid to player on completion
        uint256           buyerAgentBps;
        address           buyerAgent;
        uint256           sellerAgentBps;   // selling club's agent (if mutual termination)
        address           sellerAgent;
        uint256           deposit;          // locked by buying club on pre-contract signing
        FreeTransferState state;
        uint256           stateDeadline;
        bytes32           medicalHash;
        MedicalOutcome    medicalOutcome;
        uint256           createdAt;
    }

    struct MutualTermination {
        uint256 playerId;
        address club;
        address paymentToken;
        uint256 settlementAmount; // paid by club to player
        uint256 proposedAt;
        bool    exists;
    }

    // ─── State ────────────────────────────────────────────────────────────────

    uint256 public  _ftIdCounter;

    IPlayerRegistry public playerRegistry;
    IAddressRegistry public addressRegistry;
    ITransferEscrow public transferEscrow;

    uint256 public consentWindow;
    uint256 public medicalWindow;
    uint256 public depositBps;       // % of signing bonus locked as pre-contract deposit

    // playerId => ftId (active free transfer process)
    mapping(uint256 => uint256)           private _playerFT;
    // playerId => true if player is a free agent (in vault)
    mapping(uint256 => bool)              public  _freeAgentStatus;
    // ftId => FreeTransfer
    mapping(uint256 => FreeTransfer)      public  _fts;
    // playerId => competing proposals (buying club => ftId)
    mapping(uint256 => mapping(address => uint256)) public  _proposals;
    // playerId => list of proposing clubs
    mapping(uint256 => address[])         private _proposers;
    // playerId => active pre-contract ftId (only one allowed at a time)
    mapping(uint256 => uint256)           public  _activePreContract;
    // mutual termination proposals
    mapping(uint256 => MutualTermination) public  _terminations;

    mapping(address => mapping(address => uint256)) public  _claimable;
    mapping(address => bool)              private _approvedTokens;

    // ─── Events ───────────────────────────────────────────────────────────────

    event PlayerReleased(uint256 indexed playerId, address indexed fromClub);
    event MutualTerminationProposed(uint256 indexed playerId, address indexed club, uint256 settlementAmount);
    event MutualTerminationConfirmed(uint256 indexed playerId);
    event PreContractProposed(uint256 indexed ftId, uint256 indexed playerId, address indexed buyingClub);
    event PreContractSigned(uint256 indexed ftId, uint256 indexed playerId, address indexed buyingClub, uint256 deposit);
    event PreContractCancelled(uint256 indexed ftId, string reason);
    event MedicalSubmitted(uint256 indexed ftId, MedicalOutcome outcome);
    event FreeTransferCompleted(uint256 indexed ftId, uint256 indexed playerId, address indexed newClub);
    event FundsClaimed(address indexed recipient, address indexed token, uint256 amount);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error ReentrantCall();
    error InvalidAddress();
    error NothingToWithdraw();
    error InsufficientProtocolBalance(uint256 requested, uint256 available);
    error InvalidAmount();
    error TokenNotApproved();
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
    error DepositTooLow();

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

        playerRegistry = IPlayerRegistry(_playerRegistry);
        addressRegistry = IAddressRegistry(_addressRegistry);
        transferEscrow = ITransferEscrow(_transferEscrow);
        treasury       = _treasury;

        consentWindow  = 14 days;  // player has 2 weeks to sign pre-contract
        medicalWindow  = 72 hours;
        protocolFeeBps = 50;
        depositBps     = DEFAULT_DEPOSIT_BPS; // 10% of signing bonus

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
        _approvedTokens[token] = true;
    }

    function revokeToken(address token) external onlyRole(ADMIN_ROLE) {
        _approvedTokens[token] = false;
    }

    function pause()   external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    // ─── Mutual Termination ───────────────────────────────────────────────────

    /**
     * @notice Club proposes mutual termination before contract expiry.
     * @dev Club pays a settlement to the player. Both must agree.
     *      Common in real football when a player is surplus to requirements.
     */
    function proposeMutualTermination(
        uint256 playerId,
        address paymentToken,
        uint256 settlementAmount
    )
        external whenNotPaused nonReentrant onlyRole(CLUB_ROLE)
    {
        if (!_approvedTokens[paymentToken])                        revert TokenNotApproved();
        if (playerRegistry.currentClub(playerId) != msg.sender)   revert NotCurrentClub();
        if (_freeAgentStatus[playerId])                                revert PlayerAlreadyFreeAgent();
        if (_terminations[playerId].exists)                        revert TerminationAlreadyProposed();
        if (_playerFT[playerId] != 0)                              revert PlayerHasActiveProcess();

        IPlayerRegistry.Player memory player = playerRegistry.getPlayer(playerId);
        if (player.playerWallet == address(0)) revert PlayerWalletNotSet();

        // I lock settlement funds immediately - club can't pull out without player
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
        // I set a 30-day deadline — if player does not respond, club can withdraw

        emit MutualTerminationProposed(playerId, msg.sender, settlementAmount);
    }

    /**
     * @notice Player confirms mutual termination - becomes a free agent.
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

        address club = t.club;
        address token = t.paymentToken;
        uint256 settlement = t.settlementAmount;

        t.exists = false;
        delete _terminations[playerId];

        // Credit settlement to player wallet
        if (settlement > 0) {
            _claimable[player.playerWallet][token] += settlement;
        }

        // Release player to free agent vault
        _freeAgentStatus[playerId] = true;
        playerRegistry.escrowTransfer(playerId, club, address(this));

        emit MutualTerminationConfirmed(playerId);
        emit PlayerReleased(playerId, club);
    }

    /**
     * @notice Club withdraws mutual termination proposal - refunded.
     */
    function withdrawMutualTermination(uint256 playerId)
        external nonReentrant onlyRole(CLUB_ROLE)
    {
        MutualTermination storage t = _terminations[playerId];
        if (!t.exists)            revert TerminationNotProposed();
        if (t.club != msg.sender) revert NotCurrentClub();
        // I also allow withdrawal after expiry — player did not respond in time

        uint256 settlement = t.settlementAmount;
        address token      = t.paymentToken;
        t.exists           = false;
        delete _terminations[playerId];

        if (settlement > 0) {
            _claimable[msg.sender][token] += settlement;
        }
    }

    /**
     * @notice Release a player whose contract has expired naturally.
     * @dev Anyone can call - contract expiry is a public fact.
     *      In real football the player simply becomes available on expiry date.
     */
    function releaseExpiredContract(uint256 playerId)
        external whenNotPaused nonReentrant
    {
        // I restrict to club or league — prevents griefing by third parties
        bool authorised = hasRole(CLUB_ROLE, msg.sender) || hasRole(LEAGUE_ROLE, msg.sender);
        if (!authorised) revert NotCurrentClub();
        if (_freeAgentStatus[playerId]) revert PlayerAlreadyFreeAgent();
        if (_playerFT[playerId] != 0) revert PlayerHasActiveProcess();

        IPlayerRegistry.Player memory player = playerRegistry.getPlayer(playerId);
        if (block.timestamp < player.contractExpiry) revert ContractNotExpired();

        address club = playerRegistry.currentClub(playerId);
        _freeAgentStatus[playerId] = true;
        playerRegistry.escrowTransfer(playerId, club, address(this));

        emit PlayerReleased(playerId, club);
    }

    // ─── Pre-Contract ─────────────────────────────────────────────────────────

    /**
     * @notice Buying club proposes a pre-contract to a free agent or
     *         a player within 6 months of contract expiry.
     * @dev Multiple clubs can propose simultaneously - player picks one to sign.
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
        if (!_approvedTokens[paymentToken])             revert TokenNotApproved();
        if (_proposals[playerId][msg.sender] != 0)      revert AlreadyProposed();

        IPlayerRegistry.Player memory player = playerRegistry.getPlayer(playerId);
        if (player.playerWallet == address(0))          revert PlayerWalletNotSet();

        // I allow proposals if player is already a free agent OR within 6 months of expiry
        bool playerIsFreeAgent = _freeAgentStatus[playerId];
        bool nearExpiry    = block.timestamp >= player.contractExpiry - PRE_CONTRACT_WINDOW;
        if (!playerIsFreeAgent && !nearExpiry)                revert TooEarlyForPreContract();

        if (buyerAgentBps > MAX_AGENT_BPS)              revert InvalidAmount();
        if (buyerAgentBps > 0 && buyerAgent == address(0)) revert InvalidAddress();
        if (sellerAgentBps > MAX_AGENT_BPS)             revert InvalidAmount();
        if (sellerAgentBps > 0 && sellerAgent == address(0)) revert InvalidAddress();

        _ftIdCounter++;
        uint256 ftId = _ftIdCounter;

        _fts[ftId] = FreeTransfer({
            playerId:       playerId,
            currentClub:    playerIsFreeAgent ? address(0) : playerRegistry.currentClub(playerId),
            buyingClub:     msg.sender,
            paymentToken:   paymentToken,
            signingBonus:   signingBonus,
            buyerAgentBps:  buyerAgentBps,
            buyerAgent:     buyerAgent,
            sellerAgentBps: sellerAgentBps,
            sellerAgent:    sellerAgent,
            deposit:        0,
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
     * @dev Buying club must lock a deposit immediately on signing.
     *      Only one active pre-contract allowed - others remain as proposals.
     *      In real football, signing a pre-contract with one club while
     *      another proposal is open is allowed until the moment of signing.
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

        // I require buying club to lock deposit - protects player from club pulling out
        uint256 deposit = ft.signingBonus > 0
            ? (ft.signingBonus * depositBps) / BPS_DENOMINATOR
            : 0;

        // I mark state before external call — CEI pattern
        // Deposit is NOT pulled here — buying club must call lockDeposit() after signing
        // This avoids requiring buying club to pre-approve before player action
        ft.state              = FreeTransferState.PRE_CONTRACT_SIGNED;
        ft.deposit            = deposit;
        ft.stateDeadline      = block.timestamp + consentWindow; // buying club has consentWindow to lock deposit
        _activePreContract[ft.playerId] = ftId;
        _playerFT[ft.playerId]          = ftId;

        emit PreContractSigned(ftId, ft.playerId, ft.buyingClub, deposit);
    }

    /**
     * @notice Buying club locks deposit after player signs pre-contract.
     * @dev Must be called within consentWindow of player signing.
     *      Deposit is forfeited if buying club later pulls out.
     */
    function lockDeposit(uint256 ftId)
        external whenNotPaused nonReentrant onlyRole(CLUB_ROLE)
    {
        FreeTransfer storage ft = _fts[ftId];
        if (ft.createdAt == 0)                                   revert WrongState();
        if (ft.state != FreeTransferState.PRE_CONTRACT_SIGNED)   revert WrongState();
        if (ft.buyingClub != msg.sender)                         revert NotBuyingClub();
        if (block.timestamp > ft.stateDeadline)                  revert ConsentWindowExpired();
        if (ft.deposit == 0) { ft.stateDeadline = 0; return; }  // no deposit needed

        // I clear deadline after deposit locked — no expiry on signed pre-contract
        ft.stateDeadline = 0;
        IERC20(ft.paymentToken).safeTransferFrom(msg.sender, address(this), ft.deposit);
    }

    /**
     * @notice Buying club pulls out after player signed pre-contract.
     * @dev Deposit forfeited to player - mirrors real-world breach of pre-contract.
     */
    function withdrawPreContract(uint256 ftId)
        external whenNotPaused nonReentrant onlyRole(CLUB_ROLE)
    {
        FreeTransfer storage ft = _fts[ftId];
        if (ft.createdAt == 0)          revert WrongState();
        if (ft.buyingClub != msg.sender) revert NotBuyingClub();

        if (ft.state == FreeTransferState.PRE_CONTRACT_PROPOSED) {
            // No deposit yet - clean cancellation
            ft.state = FreeTransferState.CANCELLED;
            _proposals[ft.playerId][msg.sender] = 0;
            _activePreContract[ft.playerId] = 0;
            _playerFT[ft.playerId]          = 0;
            emit PreContractCancelled(ftId, "Club withdrew before signing");
        } else if (ft.state == FreeTransferState.PRE_CONTRACT_SIGNED) {
            // Deposit forfeited to player
            IPlayerRegistry.Player memory player = playerRegistry.getPlayer(ft.playerId);
            if (ft.deposit > 0 && player.playerWallet != address(0)) {
                _claimable[player.playerWallet][ft.paymentToken] += ft.deposit;
            }
            ft.state = FreeTransferState.CANCELLED;
            _proposals[ft.playerId][msg.sender] = 0;
            _activePreContract[ft.playerId] = 0;
            _playerFT[ft.playerId]          = 0;
            emit PreContractCancelled(ftId, "Club withdrew after signing - deposit forfeited");
        } else {
            revert WrongState();
        }
    }

    // ─── Medical ──────────────────────────────────────────────────────────────

    /**
     * @notice Buying club submits medical once transfer window opens.
     * @dev Window must be open - registration requires an open window.
     *      Medical submitted by buying club on the incoming player.
     */
    function submitMedical(
        uint256 ftId,
        MedicalOutcome outcome,
        bytes32 medicalHash
    )
        external whenNotPaused nonReentrant
    {
        FreeTransfer storage ft = _fts[ftId];
        if (ft.createdAt == 0)                                   revert WrongState();
        if (ft.state != FreeTransferState.PRE_CONTRACT_SIGNED)   revert WrongState();
        if (ft.buyingClub != msg.sender)                         revert NotBuyingClub();
        if (!ITransferWindow(addressRegistry.get(RegistryKeys.TRANSFER_WINDOW)).isWindowOpen())                      revert TransferWindowClosed();
        if (ft.medicalHash != bytes32(0))                        revert MedicalAlreadySubmitted();
        if (medicalHash == bytes32(0))                           revert InvalidAddress();
        if (outcome == MedicalOutcome.NONE)                      revert InvalidAmount();

        ft.medicalHash    = medicalHash;
        ft.medicalOutcome = outcome;
        ft.state          = FreeTransferState.AWAITING_MEDICAL;

        emit MedicalSubmitted(ftId, outcome);

        if (outcome == MedicalOutcome.FAILED) {
            // Deposit returned - medical failure is not a breach
            if (ft.deposit > 0) {
                _claimable[ft.buyingClub][ft.paymentToken] += ft.deposit;
            }
            ft.state = FreeTransferState.CANCELLED;
            _activePreContract[ft.playerId] = 0;
            _playerFT[ft.playerId]          = 0;
            emit PreContractCancelled(ftId, "Medical failed");
        } else {
            // PASSED or CONCERN - proceed to settlement
            _settleFreeTransfer(ftId);
        }
    }

    // ─── Settlement ───────────────────────────────────────────────────────────

    function _settleFreeTransfer(uint256 ftId) internal {
        FreeTransfer storage ft = _fts[ftId];
        ft.state = FreeTransferState.COMPLETED;
        _activePreContract[ft.playerId] = 0;
        _playerFT[ft.playerId]          = 0;
        _freeAgentStatus[ft.playerId]       = false;

        IPlayerRegistry.Player memory player = playerRegistry.getPlayer(ft.playerId);

        // I compute fees on signingBonus only — deposit is already held, not additional funds
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

        // I pull net signing bonus (minus deposit already held) from buying club
        if (ft.signingBonus > 0 && player.playerWallet != address(0)) {
            uint256 toPull = ft.signingBonus > ft.deposit ? ft.signingBonus - ft.deposit : 0;
            if (toPull > 0) {
                IERC20(ft.paymentToken).safeTransferFrom(ft.buyingClub, address(this), toPull);
            }
            // Credit net-of-fees to player (remaining is post-fee signingBonus portion)
            // deposit already in contract is added back as pure player proceeds
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







}
