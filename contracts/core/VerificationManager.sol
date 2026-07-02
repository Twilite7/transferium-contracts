// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IPlayerRegistry.sol";

interface IPlayerRegistryForVerification {
    // reads
    function getPlayer(uint256 playerId)         external view returns (IPlayerRegistry.Player memory);
    function getLegalDocuments(uint256 playerId) external view returns (IPlayerRegistry.LegalDocuments memory);
    function getClubRegistrar(address club)      external view returns (address);
    function getRegistrarFee(address registrar)  external view returns (uint256);
    function currentClub(uint256 playerId)       external view returns (address);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function paused()              external view returns (bool);
    function totalPausedDuration() external view returns (uint256);
    function protocolFeeBps()      external view returns (uint16);
    function baseVerificationFee() external view returns (uint64);
    function EURC()                external view returns (IERC20);

    // callbacks — VerificationManager must hold VERIFICATION_ROLE
    function setVerificationActive(uint256 playerId, bool active)       external;
    function setMedicalVerified(uint256 playerId, address actor)         external;
    function setLegalDocsVerified(uint256 playerId, address actor)       external;
    function markPlayerVerified(uint256 playerId, address actor)         external;
    function addProtocolFees(uint256 amount)                             external;
    function addRegistrarFees(address registrar, uint256 amount)         external;
    function resetWallet(uint256 playerId, address actor)                external;
}

/**
 * @title  VerificationManager
 * @author Transferium Protocol
 * @notice Manages the full player verification lifecycle.
 * @dev    Extracted from PlayerRegistry to keep it under the 24,576-byte limit.
 *         Must be granted VERIFICATION_ROLE on PlayerRegistry.
 *
 *         Flow:
 *           1. Club calls requestVerification — fee locked here in EURC.
 *           2. Registrar calls verifyMedicalClearance then verifyLegalDocuments
 *              (either order), then verifyPlayer as the final sign-off.
 *           3. verifyPlayer — full fee transferred to PlayerRegistry and split
 *              between registrar claimable and protocol accumulator.
 *           4. rejectVerification — same fee split as approval; registrar is
 *              compensated for their time. Club may fix documents and retry.
 *           5. claimVerificationRefund — full refund to club if:
 *                (a) 72-hour window expired with no registrar action, OR
 *                (b) assigned registrar's role was revoked (club not at fault).
 *
 *         EURC custody:
 *           Locked in VerificationManager until resolution.
 *           On approval/rejection: single transfer to PlayerRegistry,
 *           then addProtocolFees + addRegistrarFees update accumulators.
 *           On refund: transfer directly back to club.
 */
contract VerificationManager is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Constants ────────────────────────────────────────────────────────────

    uint256 public constant VERIFICATION_TIMEOUT     = 72 hours;
    uint256 public constant MAX_REGISTRAR_FEE_EXCESS = 2_000;
    uint256 public constant MAX_FEE                  = 10_000 * 1e6;
    bytes32 public constant REGISTRAR_ROLE           = keccak256("REGISTRAR_ROLE");

    // ─── State ────────────────────────────────────────────────────────────────

    IPlayerRegistryForVerification public playerRegistry;
    address public admin;

    /// @dev Per-player verification escrow using the struct from IPlayerRegistry.
    mapping(uint256 => IPlayerRegistry.VerificationRequest) private _verificationRequests;

    /// @dev Tracks whether each verification step was completed in the current
    ///      request. Stored separately because IPlayerRegistry.VerificationRequest
    ///      does not carry these flags, and adding them would break the shared
    ///      interface for no benefit to consumers of that interface.
    mapping(uint256 => bool) private _medicalDoneInRequest;
    mapping(uint256 => bool) private _legalDoneInRequest;

    // ─── Events ───────────────────────────────────────────────────────────────

    event VerificationRequested(
        uint256 indexed playerId,
        address indexed club,
        uint256 fee,
        uint256 deadline
    );
    event VerificationApproved(uint256 indexed playerId, address indexed registrar);
    event VerificationRejected(uint256 indexed playerId, address indexed registrar, string reason);
    event VerificationRefundClaimed(
        uint256 indexed playerId,
        address indexed club,
        uint256 amount
    );
    event MedicalClearanceVerified(uint256 indexed playerId, address indexed registrar);
    event LegalDocumentsVerified(uint256 indexed playerId, address indexed registrar);
    event FeesDistributed(
        uint256 indexed playerId,
        address indexed registrar,
        uint256 registrarAmount,
        uint256 protocolAmount
    );

    // ─── Errors ───────────────────────────────────────────────────────────────

    error ZeroAddress();
    error NotAdmin();
    error InvalidRejectionReason();
    error RegistryPaused();
    error PlayerAlreadyVerified(uint256 playerId);
    error VerificationAlreadyActive(uint256 playerId);
    error NoActiveVerificationRequest(uint256 playerId);
    error VerificationDeadlineNotPassed(uint256 playerId, uint256 adjustedDeadline, uint256 now_);
    error MedicalNotSubmitted(uint256 playerId);
    error MedicalAlreadyVerifiedInRequest(uint256 playerId);
    error MedicalNotVerifiedInRequest(uint256 playerId);
    error LegalDocsNotSubmitted(uint256 playerId);
    error LegalAlreadyVerifiedInRequest(uint256 playerId);
    error LegalDocsNotVerifiedInRequest(uint256 playerId);
    error PlayerWalletNotSet(uint256 playerId);
    error RegistrarNotAssignedToClub(address club);
    error RegistrarNotRegistered(address registrar);
    error RegistrarFeeTooHigh(uint256 provided, uint256 maxAllowed);
    error FeeTooHigh(uint256 provided, uint256 max);
    error CallerIsNotPlayerClub(uint256 playerId, address caller);
    error CallerIsNotAssignedRegistrar(uint256 playerId, address caller, address expected);

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier whenRegistryNotPaused() {
        if (playerRegistry.paused()) revert RegistryPaused();
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(address registry_, address admin_) {
        if (registry_ == address(0)) revert ZeroAddress();
        if (admin_    == address(0)) revert ZeroAddress();
        playerRegistry = IPlayerRegistryForVerification(registry_);
        admin          = admin_;
    }

    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        admin = newAdmin;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CLUB — Request verification
    // ═══════════════════════════════════════════════════════════════════════════

    function requestVerification(uint256 playerId)
        external
        whenRegistryNotPaused
        nonReentrant
    {
        // I confirm the caller is the current club for this player.
        address club = playerRegistry.currentClub(playerId);
        if (msg.sender != club) revert CallerIsNotPlayerClub(playerId, msg.sender);

        IPlayerRegistry.Player memory p = playerRegistry.getPlayer(playerId);

        if (p.isVerified)                           revert PlayerAlreadyVerified(playerId);
        if (_verificationRequests[playerId].active) revert VerificationAlreadyActive(playerId);

        // I check all prerequisites before locking any funds so the club
        // cannot waste a fee attempt on an incomplete application.
        if (!p.medicalClearance) revert MedicalNotSubmitted(playerId);

        if (playerRegistry.getLegalDocuments(playerId).registrationContractHash == bytes32(0))
            revert LegalDocsNotSubmitted(playerId);

        if (p.playerWallet == address(0)) revert PlayerWalletNotSet(playerId);

        address registrar = playerRegistry.getClubRegistrar(club);
        if (registrar == address(0))
            revert RegistrarNotAssignedToClub(club);
        if (!playerRegistry.hasRole(REGISTRAR_ROLE, registrar))
            revert RegistrarNotRegistered(registrar);

        uint256 fee  = playerRegistry.getRegistrarFee(registrar);
        uint64  base = playerRegistry.baseVerificationFee();
        if (base > 0) {
            uint256 maxAllowed = base + (uint256(base) * MAX_REGISTRAR_FEE_EXCESS / 10_000);
            if (fee > maxAllowed) revert RegistrarFeeTooHigh(fee, maxAllowed);
        }

        uint256 deadline = block.timestamp + VERIFICATION_TIMEOUT;

        // EFFECTS — record state before any external interactions.
        _verificationRequests[playerId] = IPlayerRegistry.VerificationRequest({
            feePaid:       fee,
            deadline:      deadline,
            pauseSnapshot: playerRegistry.totalPausedDuration(),
            active:        true
        });
        _medicalDoneInRequest[playerId] = false;
        _legalDoneInRequest[playerId]   = false;

        // INTERACTIONS — transfer fee, then gate document changes in PlayerRegistry.
        if (fee > 0) {
            playerRegistry.EURC().safeTransferFrom(msg.sender, address(this), fee);
        }
        playerRegistry.setVerificationActive(playerId, true);

        emit VerificationRequested(playerId, msg.sender, fee, deadline);
    }

    /**
     * @notice Refund the locked fee to the club if:
     *           (a) The 72-hour window has expired with no registrar action, OR
     *           (b) The assigned registrar has since had their role revoked.
     */
    function claimVerificationRefund(uint256 playerId)
        external
        whenRegistryNotPaused
        nonReentrant
    {
        address club = playerRegistry.currentClub(playerId);
        if (msg.sender != club) revert CallerIsNotPlayerClub(playerId, msg.sender);

        IPlayerRegistry.VerificationRequest storage req = _verificationRequests[playerId];
        if (!req.active) revert NoActiveVerificationRequest(playerId);

        // I allow an immediate refund if the registrar's role was revoked —
        // the club should not be penalised for an administrative change outside
        // their control.
        address registrar     = _getClubRegistrar(playerId);
        bool registrarRevoked = !playerRegistry.hasRole(REGISTRAR_ROLE, registrar);

        if (!registrarRevoked) {
            // I adjust the deadline by any time the registry was paused after
            // the request was made, so pauses don't count against the club.
            uint256 pausedSince      = playerRegistry.totalPausedDuration() - req.pauseSnapshot;
            uint256 deadline_ = req.deadline + pausedSince;
            if (block.timestamp <= deadline_)
                revert VerificationDeadlineNotPassed(playerId, deadline_, block.timestamp);
        }

        // EFFECTS
        uint256 refund = req.feePaid;
        req.active  = false;
        req.feePaid = 0;
        _medicalDoneInRequest[playerId] = false;
        _legalDoneInRequest[playerId]   = false;

        // INTERACTIONS
        playerRegistry.setVerificationActive(playerId, false);
        if (refund > 0) {
            playerRegistry.EURC().safeTransfer(msg.sender, refund);
        }

        emit VerificationRefundClaimed(playerId, msg.sender, refund);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // REGISTRAR — Verification steps
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Sign off on the submitted medical hash. Can be called before or
     *         after verifyLegalDocuments. Cannot be called twice per request.
     */
    function verifyMedicalClearance(uint256 playerId) external whenRegistryNotPaused {
        _assertAssignedRegistrar(playerId);

        IPlayerRegistry.VerificationRequest storage req = _verificationRequests[playerId];
        if (!req.active)                     revert NoActiveVerificationRequest(playerId);
        if (_medicalDoneInRequest[playerId]) revert MedicalAlreadyVerifiedInRequest(playerId);

        if (!playerRegistry.getPlayer(playerId).medicalClearance)
            revert MedicalNotSubmitted(playerId);

        // EFFECTS
        _medicalDoneInRequest[playerId] = true;

        // INTERACTIONS
        playerRegistry.setMedicalVerified(playerId, msg.sender);

        emit MedicalClearanceVerified(playerId, msg.sender);
    }

    /**
     * @notice Sign off on the submitted legal document hashes. Can be called
     *         before or after verifyMedicalClearance. Cannot be called twice.
     */
    function verifyLegalDocuments(uint256 playerId) external whenRegistryNotPaused {
        _assertAssignedRegistrar(playerId);

        IPlayerRegistry.VerificationRequest storage req = _verificationRequests[playerId];
        if (!req.active)                   revert NoActiveVerificationRequest(playerId);
        if (_legalDoneInRequest[playerId]) revert LegalAlreadyVerifiedInRequest(playerId);

        if (playerRegistry.getLegalDocuments(playerId).registrationContractHash == bytes32(0))
            revert LegalDocsNotSubmitted(playerId);

        // EFFECTS
        _legalDoneInRequest[playerId] = true;

        // INTERACTIONS
        playerRegistry.setLegalDocsVerified(playerId, msg.sender);

        emit LegalDocumentsVerified(playerId, msg.sender);
    }

    /**
     * @notice Final registrar sign-off. Both prior steps must have been
     *         completed within this request before this is accepted.
     */
    function verifyPlayer(uint256 playerId)
        external
        whenRegistryNotPaused
        nonReentrant
    {
        _assertAssignedRegistrar(playerId);

        IPlayerRegistry.VerificationRequest storage req = _verificationRequests[playerId];
        if (!req.active)                      revert NoActiveVerificationRequest(playerId);
        if (!_medicalDoneInRequest[playerId]) revert MedicalNotVerifiedInRequest(playerId);
        if (!_legalDoneInRequest[playerId])   revert LegalDocsNotVerifiedInRequest(playerId);

        IPlayerRegistry.Player memory p = playerRegistry.getPlayer(playerId);
        if (p.isVerified)              revert PlayerAlreadyVerified(playerId);
        // I re-check wallet as a final guard in case resetWallet was called
        // between requestVerification and now.
        if (p.playerWallet == address(0)) revert PlayerWalletNotSet(playerId);

        // EFFECTS — clear request state before any external calls.
        uint256 fee       = req.feePaid;
        address registrar = msg.sender;
        req.active  = false;
        req.feePaid = 0;
        _medicalDoneInRequest[playerId] = false;
        _legalDoneInRequest[playerId]   = false;

        // INTERACTIONS
        playerRegistry.setVerificationActive(playerId, false);
        playerRegistry.markPlayerVerified(playerId, registrar);
        _splitFee(playerId, fee, registrar);

        emit VerificationApproved(playerId, registrar);
    }

    /**
     * @notice Registrar explicitly rejects the verification. The fee is
     *         distributed (registrar compensated for their work). The club
     *         may correct documents and submit a new request.
     */
    function rejectVerification(uint256 playerId, string calldata reason)
        external
        whenRegistryNotPaused
        nonReentrant
    {
        if (bytes(reason).length == 0 || bytes(reason).length > 512)
            revert InvalidRejectionReason();
        _assertAssignedRegistrar(playerId);

        IPlayerRegistry.VerificationRequest storage req = _verificationRequests[playerId];
        if (!req.active) revert NoActiveVerificationRequest(playerId);

        // EFFECTS
        uint256 fee       = req.feePaid;
        address registrar = msg.sender;
        req.active  = false;
        req.feePaid = 0;
        _medicalDoneInRequest[playerId] = false;
        _legalDoneInRequest[playerId]   = false;

        // INTERACTIONS
        playerRegistry.setVerificationActive(playerId, false);
        _splitFee(playerId, fee, registrar);

        emit VerificationRejected(playerId, registrar, reason);
    }

    /**
     * @notice Registrar resets a player's wallet to zero (recovery path if
     *         the player's wallet was compromised). Club then calls
     *         setPlayerWallet to assign a new address.
     */
    function resetPlayerWallet(uint256 playerId) external whenRegistryNotPaused {
        _assertAssignedRegistrar(playerId);
        playerRegistry.resetWallet(playerId, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW
    // ═══════════════════════════════════════════════════════════════════════════

    function getVerificationRequest(uint256 playerId)
        external view
        returns (IPlayerRegistry.VerificationRequest memory)
    {
        return _verificationRequests[playerId];
    }

    function isMedicalVerifiedInRequest(uint256 playerId) external view returns (bool) {
        return _medicalDoneInRequest[playerId];
    }

    function isLegalVerifiedInRequest(uint256 playerId) external view returns (bool) {
        return _legalDoneInRequest[playerId];
    }

    /**
     * @notice Returns the pause-adjusted deadline for an active request.
     *         Returns 0 if there is no active request for this player.
     */
    function adjustedDeadline(uint256 playerId) external view returns (uint256) {
        IPlayerRegistry.VerificationRequest storage req = _verificationRequests[playerId];
        if (!req.active) return 0;
        uint256 pausedSince = playerRegistry.totalPausedDuration() - req.pauseSnapshot;
        return req.deadline + pausedSince;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════════════════

    function _assertAssignedRegistrar(uint256 playerId) internal view {
        address club      = playerRegistry.currentClub(playerId);
        address registrar = playerRegistry.getClubRegistrar(club);
        if (registrar == address(0)) revert RegistrarNotAssignedToClub(club);
        if (registrar != msg.sender)
            revert CallerIsNotAssignedRegistrar(playerId, msg.sender, registrar);
    }

    /// @dev Returns the registrar assigned to the club currently holding this
    ///      player. Used in claimVerificationRefund to check revocation without
    ///      reverting when the registrar address is zero.
    function _getClubRegistrar(uint256 playerId) internal view returns (address) {
        address club = playerRegistry.currentClub(playerId);
        return playerRegistry.getClubRegistrar(club);
    }

    /**
     * @notice Transfer the full fee to PlayerRegistry in one EURC call, then
     *         credit the split via the two accounting callbacks.
     *
     *         Rounding: protocolCut rounds UP so the protocol is never
     *         short-changed by integer division. Registrar receives the remainder.
     *         Guard: protocolCut is capped at fee to prevent overflow on
     *         extreme bps values.
     */
    function _splitFee(uint256 playerId, uint256 fee, address registrar) internal {
        if (fee == 0) return;

        uint256 bps         = playerRegistry.protocolFeeBps();
        uint256 protocolCut = (fee * bps + 9_999) / 10_000;
        if (protocolCut > fee) protocolCut = fee;
        uint256 registrarCut = fee - protocolCut;

        // I transfer the full fee in a single EURC call to PlayerRegistry, then
        // use the two accounting callbacks to record the split — avoiding two
        // separate transfers to the same address.
        IERC20 eurc = playerRegistry.EURC();
        eurc.safeTransfer(address(playerRegistry), fee);

        if (registrarCut > 0) playerRegistry.addRegistrarFees(registrar, registrarCut);
        if (protocolCut  > 0) playerRegistry.addProtocolFees(protocolCut);

        emit FeesDistributed(playerId, registrar, registrarCut, protocolCut);
    }
}
