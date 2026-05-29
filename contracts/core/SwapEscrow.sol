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
 * @title SwapEscrow
 * @author Transferium Protocol
 * @notice Handles player-for-player swaps with optional cash top-up.
 *
 * @dev Real-world swap rules modelled:
 *      - Both players must consent independently
 *      - Both clubs submit medicals on incoming player
 *      - Cash top-up paid by one club (optional)
 *      - One medical failure cancels entire swap
 *      - Both NFTs transfer atomically at settlement
 *      - Transfer window must be open throughout
 *
 * Flow:
 *   Club A proposes -> Club B accepts ->
 *   Player A consents -> Player B consents ->
 *   Club A submits medical on Player B ->
 *   Club B submits medical on Player A ->
 *   Club B funds top-up ->
 *   Dispute window -> COMPLETED
 */
contract SwapEscrow is
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

    // ---- Roles ---------------------------------------------------------------

    bytes32 public constant ADMIN_ROLE  = keccak256("ADMIN_ROLE");
    bytes32 public constant CLUB_ROLE   = keccak256("CLUB_ROLE");
    bytes32 public constant LEAGUE_ROLE = keccak256("LEAGUE_ROLE");

    // ---- Constants -----------------------------------------------------------

    uint256 public constant MAX_AGENT_BPS        = 300;
    uint256 public constant BPS_DENOMINATOR      = 10_000;
    uint256 public constant MAX_PRICE            = 500_000_000 ether;
    uint256 public constant MIN_WINDOW           = 1 hours;

    // ---- Enums ---------------------------------------------------------------

    enum SwapState {
        NONE,
        PROPOSED,                  // Club A proposed, waiting for Club B
        ACCEPTED,                  // Club B accepted, waiting for consents
        PLAYER_A_CONSENTED,        // Player A consented, waiting for Player B
        BOTH_CONSENTED,            // Both consented, waiting for medicals
        CLUB_A_MEDICAL_DONE,       // Club A submitted medical on Player B
        BOTH_MEDICALS_DONE,        // Both medicals done, waiting for funding
        FUNDED,                    // Top-up funded, dispute window active
        DISPUTE,                   // Dispute raised
        COMPLETED,
        CANCELLED
    }

    enum MedicalOutcome { NONE, PASSED, FAILED, CONCERN }

    // ---- Structs -------------------------------------------------------------

    struct Swap {
        uint256       playerA;          // Club A's player going to Club B
        uint256       playerB;          // Club B's player going to Club A
        address       clubA;
        address       clubB;
        address       paymentToken;     // token for cash top-up
        uint256       topUpAmount;      // paid by Club B to Club A (0 if pure swap)
        uint256       clubAAgentBps;    // Club A's agent fee (on top-up)
        address       clubAAgent;
        uint256       clubBAgentBps;    // Club B's agent fee (on top-up)
        address       clubBAgent;
        SwapState     state;
        uint256       stateDeadline;
        // medicals
        bytes32       medicalHashAonB;  // Club A's medical on Player B
        bytes32       medicalHashBonA;  // Club B's medical on Player A
        MedicalOutcome medicalAonB;
        MedicalOutcome medicalBonA;
        // funding
        bool          funded;
        uint256       createdAt;
        uint256       fundedAt;
        uint256       disputeDeadline;
        // mutual cancel
        address       cancelProposer;
        uint256       cancelDeadline;
    }

    // ---- State ---------------------------------------------------------------

    uint256 private _swapIdCounter;

    IPlayerRegistry public playerRegistry;
    IAddressRegistry public addressRegistry;
    ITransferEscrow public transferEscrow;

    uint256 public consentWindow;
    uint256 public medicalWindow;
    uint256 public fundingWindow;
    uint256 public disputeWindow;
    uint256 public mutualCancelWindow;

    mapping(uint256 => Swap)    private _swaps;
    // playerA or playerB => swapId (one active swap per player)
    mapping(uint256 => uint256) private _playerSwap;
    // swapId => playerId => consented
    mapping(uint256 => mapping(uint256 => bool)) private _consented;

    mapping(address => mapping(address => uint256)) private _claimable;
    mapping(address => bool) private _approvedTokens;

    // ---- Events --------------------------------------------------------------

    event SwapProposed(uint256 indexed swapId, uint256 playerA, uint256 playerB, address indexed clubA, address indexed clubB);
    event SwapAccepted(uint256 indexed swapId);
    event SwapCancelled(uint256 indexed swapId, string reason);
    event PlayerConsented(uint256 indexed swapId, uint256 indexed playerId);
    event MedicalSubmitted(uint256 indexed swapId, uint256 indexed playerId, MedicalOutcome outcome);
    event SwapFunded(uint256 indexed swapId, uint256 topUpAmount);
    event DisputeRaised(uint256 indexed swapId, address indexed raisedBy);
    event DisputeResolved(uint256 indexed swapId);
    event SwapCompleted(uint256 indexed swapId);
    event MutualCancelProposed(uint256 indexed swapId, address indexed proposer);
    event MutualCancelConfirmed(uint256 indexed swapId);
    event FundsClaimed(address indexed recipient, address indexed token, uint256 amount);

    // ---- Errors --------------------------------------------------------------

    error ReentrantCall();
    error InvalidAddress();
    error InvalidAmount();
    error NothingToWithdraw();
    error InsufficientProtocolBalance(uint256 requested, uint256 available);
    error TokenNotApproved();
    error NotClubA();
    error NotClubB();
    error NotPlayerWallet();
    error PlayerWalletNotSet();
    error WrongState();
    error SwapNotFound();
    error ConsentWindowExpired();
    error MedicalWindowExpired();
    error FundingWindowExpired();
    error DisputeWindowExpired();
    error MedicalAlreadySubmitted();
    error TransferWindowClosed();
    error NothingToClaim();
    error TimerTooShort();
    error PlayerHasActiveProcess();
    error CannotSwapSameClub();
    error MutualCancelAlreadyProposed();
    error MutualCancelNotProposed();
    error MutualCancelExpired();
    error CannotConfirmOwnCancel();
    error DealIsFrozen();

    // ---- Initializer ---------------------------------------------------------

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

        playerRegistry    = IPlayerRegistry(_playerRegistry);
        addressRegistry   = IAddressRegistry(_addressRegistry);
        transferEscrow    = ITransferEscrow(_transferEscrow);
        treasury          = _treasury;

        consentWindow     = 72 hours;
        medicalWindow     = 72 hours;
        fundingWindow     = 48 hours;
        disputeWindow     = 72 hours;
        mutualCancelWindow = 48 hours;
        protocolFeeBps    = 50;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE,         _admin);
        _grantRole(LEAGUE_ROLE,        _admin);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ---- Admin ---------------------------------------------------------------

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

    function setTimer(uint8 which, uint256 d) external onlyRole(ADMIN_ROLE) {
        if (d < MIN_WINDOW) revert TimerTooShort();
        if      (which == 0) consentWindow      = d;
        else if (which == 1) medicalWindow      = d;
        else if (which == 2) fundingWindow      = d;
        else if (which == 3) disputeWindow      = d;
        else if (which == 4) mutualCancelWindow = d;
        else revert InvalidAmount();
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

    // ---- Club A: Propose Swap ------------------------------------------------

    /**
     * @notice Club A proposes a swap of playerA for playerB.
     * @dev Transfer window must be open. Top-up (if any) paid by Club B.
     *      paymentToken required even for pure swaps (topUpAmount = 0) so the
     *      field is set for agent fee payments if needed.
     */
    function proposeSwap(
        uint256 playerA,
        uint256 playerB,
        address paymentToken,
        uint256 topUpAmount,
        uint256 clubAAgentBps,
        address clubAAgent,
        uint256 clubBAgentBps,
        address clubBAgent
    )
        external whenNotPaused nonReentrant onlyRole(CLUB_ROLE)
        returns (uint256 swapId)
    {
        if (!ITransferWindow(addressRegistry.get(RegistryKeys.TRANSFER_WINDOW)).isWindowOpen())                        revert TransferWindowClosed();
        if (!_approvedTokens[paymentToken])                        revert TokenNotApproved();
        if (playerA == playerB)                                    revert InvalidAmount();
        if (topUpAmount > MAX_PRICE)                               revert InvalidAmount();
        if (clubAAgentBps > MAX_AGENT_BPS)                         revert InvalidAmount();
        if (clubAAgentBps > 0 && clubAAgent == address(0))         revert InvalidAddress();
        if (clubBAgentBps > MAX_AGENT_BPS)                         revert InvalidAmount();
        if (clubBAgentBps > 0 && clubBAgent == address(0))         revert InvalidAddress();
        if (_playerSwap[playerA] != 0)                             revert PlayerHasActiveProcess();
        if (_playerSwap[playerB] != 0)                             revert PlayerHasActiveProcess();
        if (transferEscrow.getPlayerOffer(playerA) != 0)           revert PlayerHasActiveProcess();
        if (transferEscrow.getPlayerDeal(playerA)  != 0)           revert PlayerHasActiveProcess();
        if (transferEscrow.getPlayerOffer(playerB) != 0)           revert PlayerHasActiveProcess();
        if (transferEscrow.getPlayerDeal(playerB)  != 0)           revert PlayerHasActiveProcess();

        address clubA = msg.sender;
        address clubB = playerRegistry.currentClub(playerB);

        if (clubA == clubB)                                        revert CannotSwapSameClub();
        if (playerRegistry.currentClub(playerA) != clubA)         revert NotClubA();

        // I verify both players are fully cleared — unverified players cannot be swapped
        IPlayerRegistry.Player memory pA = playerRegistry.getPlayer(playerA);
        IPlayerRegistry.Player memory pB = playerRegistry.getPlayer(playerB);
        if (!pA.isVerified || !pA.medicalClearance) revert WrongState();
        if (!pB.isVerified || !pB.medicalClearance) revert WrongState();

        _swapIdCounter++;
        swapId = _swapIdCounter;

        _swaps[swapId] = Swap({
            playerA:        playerA,
            playerB:        playerB,
            clubA:          clubA,
            clubB:          clubB,
            paymentToken:   paymentToken,
            topUpAmount:    topUpAmount,
            clubAAgentBps:  clubAAgentBps,
            clubAAgent:     clubAAgent,
            clubBAgentBps:  clubBAgentBps,
            clubBAgent:     clubBAgent,
            state:          SwapState.PROPOSED,
            stateDeadline:  block.timestamp + consentWindow,
            medicalHashAonB: bytes32(0),
            medicalHashBonA: bytes32(0),
            medicalAonB:    MedicalOutcome.NONE,
            medicalBonA:    MedicalOutcome.NONE,
            funded:         false,
            createdAt:      block.timestamp,
            fundedAt:       0,
            disputeDeadline: 0,
            cancelProposer: address(0),
            cancelDeadline: 0
        });

        _playerSwap[playerA] = swapId;
        _playerSwap[playerB] = swapId;

        emit SwapProposed(swapId, playerA, playerB, clubA, clubB);
    }

    // ---- Club B: Accept or Reject --------------------------------------------

    function acceptSwap(uint256 swapId)
        external whenNotPaused nonReentrant onlyRole(CLUB_ROLE)
    {
        Swap storage s = _swaps[swapId];
        if (s.createdAt == 0)                    revert SwapNotFound();
        if (s.state != SwapState.PROPOSED)        revert WrongState();
        if (s.clubB != msg.sender)               revert NotClubB();
        if (block.timestamp > s.stateDeadline)   revert ConsentWindowExpired();
        if (!ITransferWindow(addressRegistry.get(RegistryKeys.TRANSFER_WINDOW)).isWindowOpen())       revert TransferWindowClosed();

        s.state         = SwapState.ACCEPTED;
        s.stateDeadline = block.timestamp + consentWindow;

        emit SwapAccepted(swapId);
    }

    function rejectSwap(uint256 swapId)
        external whenNotPaused nonReentrant onlyRole(CLUB_ROLE)
    {
        Swap storage s = _swaps[swapId];
        if (s.createdAt == 0)                    revert SwapNotFound();
        if (s.state != SwapState.PROPOSED)        revert WrongState();
        if (s.clubB != msg.sender)               revert NotClubB();

        _cancelSwap(swapId, "Club B rejected swap");
    }

    function withdrawProposal(uint256 swapId)
        external whenNotPaused nonReentrant onlyRole(CLUB_ROLE)
    {
        Swap storage s = _swaps[swapId];
        if (s.createdAt == 0)                    revert SwapNotFound();
        if (s.state != SwapState.PROPOSED)        revert WrongState();
        if (s.clubA != msg.sender)               revert NotClubA();

        _cancelSwap(swapId, "Club A withdrew proposal");
    }

    // ---- Player Consents -----------------------------------------------------

    /**
     * @notice Player consents to the swap.
     * @dev Either player can consent in any order.
     *      Both must consent before medicals can proceed.
     */
    function consentToSwap(uint256 swapId)
        external whenNotPaused nonReentrant
    {
        Swap storage s = _swaps[swapId];
        if (s.createdAt == 0)                  revert SwapNotFound();
        if (s.state != SwapState.ACCEPTED &&
            s.state != SwapState.PLAYER_A_CONSENTED) revert WrongState();
        if (block.timestamp > s.stateDeadline) revert ConsentWindowExpired();

        IPlayerRegistry.Player memory pA = playerRegistry.getPlayer(s.playerA);
        IPlayerRegistry.Player memory pB = playerRegistry.getPlayer(s.playerB);

        bool isPlayerA = pA.playerWallet != address(0) && pA.playerWallet == msg.sender;
        bool isPlayerB = pB.playerWallet != address(0) && pB.playerWallet == msg.sender;

        if (!isPlayerA && !isPlayerB) revert NotPlayerWallet();

        uint256 pid = isPlayerA ? s.playerA : s.playerB;
        // I prevent double-consent by same player
        if (_consented[swapId][pid]) revert WrongState();
        _consented[swapId][pid] = true;
        emit PlayerConsented(swapId, pid);

        bool aConsented = _consented[swapId][s.playerA];
        bool bConsented = _consented[swapId][s.playerB];

        if (aConsented && bConsented) {
            s.state         = SwapState.BOTH_CONSENTED;
            s.stateDeadline = block.timestamp + medicalWindow;
        } else {
            s.state = SwapState.PLAYER_A_CONSENTED;
        }
    }

    // ---- Medicals ------------------------------------------------------------

    /**
     * @notice Club A submits medical on Player B (incoming player).
     */
    function submitMedicalAonB(uint256 swapId, MedicalOutcome outcome, bytes32 hash)
        external whenNotPaused nonReentrant
    {
        Swap storage s = _swaps[swapId];
        if (s.createdAt == 0)                  revert SwapNotFound();
        if (s.state != SwapState.BOTH_CONSENTED &&
            s.state != SwapState.CLUB_A_MEDICAL_DONE) revert WrongState();
        if (s.clubA != msg.sender)             revert NotClubA();
        if (block.timestamp > s.stateDeadline) revert MedicalWindowExpired();
        if (s.medicalHashAonB != bytes32(0))   revert MedicalAlreadySubmitted();
        if (hash == bytes32(0))                revert InvalidAddress();
        if (outcome == MedicalOutcome.NONE)    revert InvalidAmount();

        s.medicalHashAonB = hash;
        s.medicalAonB     = outcome;
        emit MedicalSubmitted(swapId, s.playerB, outcome);

        if (outcome == MedicalOutcome.FAILED) {
            _cancelSwap(swapId, "Medical failed on Player B");
            return;
        }

        if (s.state == SwapState.CLUB_A_MEDICAL_DONE) {
            // Club B already submitted — both done
            _advanceToFunding(swapId);
        } else {
            s.state = SwapState.CLUB_A_MEDICAL_DONE;
        }
    }

    /**
     * @notice Club B submits medical on Player A (incoming player).
     */
    function submitMedicalBonA(uint256 swapId, MedicalOutcome outcome, bytes32 hash)
        external whenNotPaused nonReentrant
    {
        Swap storage s = _swaps[swapId];
        if (s.createdAt == 0)                  revert SwapNotFound();
        if (s.state != SwapState.BOTH_CONSENTED &&
            s.state != SwapState.CLUB_A_MEDICAL_DONE) revert WrongState();
        if (s.clubB != msg.sender)             revert NotClubB();
        if (block.timestamp > s.stateDeadline) revert MedicalWindowExpired();
        if (s.medicalHashBonA != bytes32(0))   revert MedicalAlreadySubmitted();
        if (hash == bytes32(0))                revert InvalidAddress();
        if (outcome == MedicalOutcome.NONE)    revert InvalidAmount();

        s.medicalHashBonA = hash;
        s.medicalBonA     = outcome;
        emit MedicalSubmitted(swapId, s.playerA, outcome);

        if (outcome == MedicalOutcome.FAILED) {
            _cancelSwap(swapId, "Medical failed on Player A");
            return;
        }

        if (s.state == SwapState.CLUB_A_MEDICAL_DONE) {
            // Club A already submitted — both done
            _advanceToFunding(swapId);
        } else {
            // Club B submitted first — wait for Club A
            s.state = SwapState.CLUB_A_MEDICAL_DONE; // reuse state — both track via hashes
        }
    }

    function _advanceToFunding(uint256 swapId) internal {
        Swap storage s = _swaps[swapId];
        if (s.topUpAmount == 0) {
            // Pure swap — no funding needed, go straight to settlement
            _settleSwap(swapId);
        } else {
            s.state         = SwapState.BOTH_MEDICALS_DONE;
            s.stateDeadline = block.timestamp + fundingWindow;
        }
    }

    // ---- Funding (Club B pays top-up) ----------------------------------------

    function fundSwap(uint256 swapId)
        external whenNotPaused nonReentrant
    {
        Swap storage s = _swaps[swapId];
        if (s.createdAt == 0)                        revert SwapNotFound();
        if (s.state != SwapState.BOTH_MEDICALS_DONE) revert WrongState();
        if (s.clubB != msg.sender)                   revert NotClubB();
        if (block.timestamp > s.stateDeadline)       revert FundingWindowExpired();
        if (!ITransferWindow(addressRegistry.get(RegistryKeys.TRANSFER_WINDOW)).isWindowOpen())           revert TransferWindowClosed();

        IERC20(s.paymentToken).safeTransferFrom(msg.sender, address(this), s.topUpAmount);

        s.funded         = true;
        s.fundedAt       = block.timestamp;
        s.state          = SwapState.FUNDED;
        s.disputeDeadline = block.timestamp + disputeWindow;
        s.stateDeadline  = s.disputeDeadline;

        emit SwapFunded(swapId, s.topUpAmount);
    }

    // ---- Dispute Window ------------------------------------------------------

    function raiseDispute(uint256 swapId) external
    {
        Swap storage s = _swaps[swapId];
        if (s.createdAt == 0)              revert SwapNotFound();
        if (s.state != SwapState.FUNDED)   revert WrongState();
        if (block.timestamp >= s.disputeDeadline) revert DisputeWindowExpired();
        if (msg.sender != s.clubA && msg.sender != s.clubB) revert WrongState();

        s.state         = SwapState.DISPUTE;
        s.stateDeadline = block.timestamp + disputeWindow; // I reset so processExpiry gives league time to resolve
        emit DisputeRaised(swapId, msg.sender);
    }

    function resolveDispute(uint256 swapId)
        external onlyRole(LEAGUE_ROLE) nonReentrant
    {
        Swap storage s = _swaps[swapId];
        if (s.createdAt == 0)              revert SwapNotFound();
        if (s.state != SwapState.DISPUTE)  revert WrongState();
        emit DisputeResolved(swapId);
        _settleSwap(swapId);
    }

    function forceCancel(uint256 swapId)
        external onlyRole(LEAGUE_ROLE) nonReentrant
    {
        Swap storage s = _swaps[swapId];
        if (s.createdAt == 0) revert SwapNotFound();
        if (s.state == SwapState.COMPLETED || s.state == SwapState.CANCELLED) revert WrongState();
        _cancelSwap(swapId, "League force cancelled");
    }

    // ---- Mutual Cancel -------------------------------------------------------

    function proposeMutualCancel(uint256 swapId) external whenNotPaused
    {
        Swap storage s = _swaps[swapId];
        if (s.createdAt == 0)              revert SwapNotFound();
        if (s.state == SwapState.COMPLETED || s.state == SwapState.CANCELLED ||
            s.state == SwapState.FUNDED    || s.state == SwapState.DISPUTE) revert WrongState();
        if (msg.sender != s.clubA && msg.sender != s.clubB) revert WrongState();
        if (s.cancelProposer != address(0)) revert MutualCancelAlreadyProposed();

        s.cancelProposer = msg.sender;
        s.cancelDeadline = block.timestamp + mutualCancelWindow;
        emit MutualCancelProposed(swapId, msg.sender);
    }

    function confirmMutualCancel(uint256 swapId)
        external whenNotPaused nonReentrant
    {
        Swap storage s = _swaps[swapId];
        if (s.createdAt == 0)                       revert SwapNotFound();
        if (s.cancelProposer == address(0))          revert MutualCancelNotProposed();
        if (block.timestamp > s.cancelDeadline)      revert MutualCancelExpired();
        if (msg.sender == s.cancelProposer)          revert CannotConfirmOwnCancel();
        if (msg.sender != s.clubA && msg.sender != s.clubB) revert WrongState();

        emit MutualCancelConfirmed(swapId);
        _cancelSwap(swapId, "Mutual cancel agreed");
    }

    // ---- Expiry Processing ---------------------------------------------------

    function processExpiry(uint256 swapId) external nonReentrant
    {
        Swap storage s = _swaps[swapId];
        if (s.createdAt == 0)                  revert SwapNotFound();
        if (s.stateDeadline == 0)              revert WrongState();
        if (block.timestamp <= s.stateDeadline) revert WrongState();

        if (s.state == SwapState.PROPOSED) {
            _cancelSwap(swapId, "Club B did not respond in time");
        } else if (s.state == SwapState.ACCEPTED ||
                   s.state == SwapState.PLAYER_A_CONSENTED) {
            _cancelSwap(swapId, "Consent window expired");
        } else if (s.state == SwapState.BOTH_CONSENTED ||
                   s.state == SwapState.CLUB_A_MEDICAL_DONE) {
            _cancelSwap(swapId, "Medical window expired");
        } else if (s.state == SwapState.BOTH_MEDICALS_DONE) {
            _cancelSwap(swapId, "Funding window expired");
        } else if (s.state == SwapState.FUNDED) {
            // Dispute window expired with no dispute - auto settle
            _settleSwap(swapId);
        } else if (s.state == SwapState.DISPUTE) {
            // League never resolved - auto settle
            _settleSwap(swapId);
        } else {
            revert WrongState();
        }
    }

    // ---- Internal Settlement -------------------------------------------------

    function _settleSwap(uint256 swapId) internal {
        Swap storage s = _swaps[swapId];
        s.state = SwapState.COMPLETED;

        _playerSwap[s.playerA] = 0;
        _playerSwap[s.playerB] = 0;
        _consented[swapId][s.playerA] = false;
        _consented[swapId][s.playerB] = false;

        // Distribute top-up fees if any
        if (s.topUpAmount > 0) {
            uint256 remaining = s.topUpAmount;

            if (protocolFeeBps > 0 && treasury != address(0)) {
                uint256 fee = (s.topUpAmount * protocolFeeBps) / BPS_DENOMINATOR;
                remaining  -= fee;
                _claimable[treasury][s.paymentToken] += fee;
            }
            if (s.clubAAgentBps > 0 && s.clubAAgent != address(0)) {
                uint256 fee = (s.topUpAmount * s.clubAAgentBps) / BPS_DENOMINATOR;
                remaining  -= fee;
                _claimable[s.clubAAgent][s.paymentToken] += fee;
            }
            if (s.clubBAgentBps > 0 && s.clubBAgent != address(0)) {
                uint256 fee = (s.topUpAmount * s.clubBAgentBps) / BPS_DENOMINATOR;
                remaining  -= fee;
                _claimable[s.clubBAgent][s.paymentToken] += fee;
            }
            // Remainder goes to Club A (receiving the top-up)
            _claimable[s.clubA][s.paymentToken] += remaining;
        }

        // Atomic NFT swap — Player A goes to Club B, Player B goes to Club A
        playerRegistry.escrowTransfer(s.playerA, s.clubA, s.clubB);
        playerRegistry.escrowTransfer(s.playerB, s.clubB, s.clubA);

        emit SwapCompleted(swapId);
    }

    function _cancelSwap(uint256 swapId, string memory reason) internal {
        Swap storage s = _swaps[swapId];
        s.state = SwapState.CANCELLED;

        _playerSwap[s.playerA] = 0;
        _playerSwap[s.playerB] = 0;
        _consented[swapId][s.playerA] = false;
        _consented[swapId][s.playerB] = false;

        // Refund top-up if it was funded
        if (s.funded && s.topUpAmount > 0) {
            _claimable[s.clubB][s.paymentToken] += s.topUpAmount;
        }

        emit SwapCancelled(swapId, reason);
    }

    // ---- Pull Withdrawal -----------------------------------------------------

    function withdrawClaimable(address token) external nonReentrant {
        uint256 amt = _claimable[msg.sender][token];
        if (amt == 0) revert NothingToClaim();
        _claimable[msg.sender][token] = 0;
        IERC20(token).safeTransfer(msg.sender, amt);
        emit FundsClaimed(msg.sender, token, amt);
    }

    // ---- Views ---------------------------------------------------------------

    function getSwap(uint256 swapId) external view returns (Swap memory) {
        return _swaps[swapId];
    }

    function getPlayerSwap(uint256 playerId) external view returns (uint256) {
        return _playerSwap[playerId];
    }

    function getClaimable(address account, address token) external view returns (uint256) {
        return _claimable[account][token];
    }

    function isTokenApproved(address token) external view returns (bool) {
        return _approvedTokens[token];
    }

    function totalSwaps() external view returns (uint256) {
        return _swapIdCounter;
    }
}
