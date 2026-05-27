// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IPlayerRegistry.sol";

interface IPlayerRegistryForVerification {
    // reads
    function getPlayer(uint256 playerId) external view returns (IPlayerRegistry.Player memory);
    function getLegalDocuments(uint256 playerId) external view returns (IPlayerRegistry.LegalDocuments memory);
    function getClubRegistrar(address club) external view returns (address);
    function getRegistrarFee(address registrar) external view returns (uint256);
    function currentClub(uint256 playerId) external view returns (address);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function paused() external view returns (bool);
    function totalPausedDuration() external view returns (uint256);
    function protocolFeeBps() external view returns (uint16);
    function baseVerificationFee() external view returns (uint64);
    function EURC() external view returns (IERC20);
    // callbacks (VERIFICATION_ROLE gated)
    function setVerificationActive(uint256 playerId, bool active) external;
    function setMedicalVerified(uint256 playerId, address actor) external;
    function setLegalDocsVerified(uint256 playerId, address actor) external;
    function markPlayerVerified(uint256 playerId, address actor) external;
    function addProtocolFees(uint256 amount) external;
    function addRegistrarFees(address registrar, uint256 amount) external;
    function resetWallet(uint256 playerId, address actor) external;
}

/**
 * @title  VerificationManager
 * @author Transferium Protocol
 * @notice Manages the full player verification lifecycle.
 * @dev    Extracted from PlayerRegistry to keep it under the 24,576-byte limit.
 *         Must be granted VERIFICATION_ROLE on PlayerRegistry.
 *         Clubs approve VerificationManager (not PlayerRegistry) for verification fees.
 */
contract VerificationManager {
    using SafeERC20 for IERC20;

    // ─── Constants ────────────────────────────────────────────────────────────

    uint256 public constant VERIFICATION_TIMEOUT     = 72 hours;
    uint256 public constant MAX_REGISTRAR_FEE_EXCESS = 2_000;
    uint256 public constant MAX_FEE                  = 10_000 * 1e6;
    bytes32 public constant REGISTRAR_ROLE           = keccak256("REGISTRAR_ROLE");

    // ─── State ────────────────────────────────────────────────────────────────

    IPlayerRegistryForVerification public playerRegistry;
    address public admin;

    mapping(uint256 => IPlayerRegistry.VerificationRequest) private _verificationRequests;

    // ─── Events ───────────────────────────────────────────────────────────────

    event VerificationRequested(uint256 indexed playerId, address club, uint256 fee, uint256 deadline);
    event VerificationApproved(uint256 indexed playerId, address registrar);
    event VerificationRejected(uint256 indexed playerId, address registrar);
    event VerificationRefundClaimed(uint256 indexed playerId, address club);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error ZeroAddress();
    error NotAdmin();
    error RegistryPaused();
    error PlayerAlreadyVerified(uint256 playerId);
    error VerificationAlreadyActive(uint256 playerId);
    error NoActiveVerificationRequest(uint256 playerId);
    error VerificationDeadlineNotPassed(uint256 playerId, uint256 adjustedDeadline, uint256 now_);
    error MedicalNotSubmitted(uint256 playerId);
    error MedicalNotVerified(uint256 playerId);
    error LegalDocsNotSubmitted(uint256 playerId);
    error LegalDocsNotVerified(uint256 playerId);
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
        external whenRegistryNotPaused
    {
        IPlayerRegistry.Player memory p = playerRegistry.getPlayer(playerId);
        address club = playerRegistry.currentClub(playerId);

        if (msg.sender != club)                          revert CallerIsNotPlayerClub(playerId, msg.sender);
        if (p.isVerified)                                revert PlayerAlreadyVerified(playerId);
        if (_verificationRequests[playerId].active)      revert VerificationAlreadyActive(playerId);
        if (!p.medicalClearance)                         revert MedicalNotSubmitted(playerId);
        if (playerRegistry.getLegalDocuments(playerId).registrationContractHash == bytes32(0))
                                                         revert LegalDocsNotSubmitted(playerId);
        if (p.playerWallet == address(0))                revert PlayerWalletNotSet(playerId);

        address registrar = playerRegistry.getClubRegistrar(club);
        if (registrar == address(0))                      revert RegistrarNotAssignedToClub(club);
        if (!playerRegistry.hasRole(REGISTRAR_ROLE, registrar)) revert RegistrarNotRegistered(registrar);

        uint256 fee = playerRegistry.getRegistrarFee(registrar);
        uint64 base = playerRegistry.baseVerificationFee();
        if (base > 0) {
            uint256 maxAllowed = base + (uint256(base) * MAX_REGISTRAR_FEE_EXCESS / 10_000);
            if (fee > maxAllowed) revert RegistrarFeeTooHigh(fee, maxAllowed);
        }

        if (fee > 0) playerRegistry.EURC().safeTransferFrom(msg.sender, address(this), fee);

        _verificationRequests[playerId] = IPlayerRegistry.VerificationRequest({
            feePaid:       fee,
            deadline:      block.timestamp + VERIFICATION_TIMEOUT,
            pauseSnapshot: playerRegistry.totalPausedDuration(),
            active:        true
        });

        playerRegistry.setVerificationActive(playerId, true);
        emit VerificationRequested(playerId, msg.sender, fee, block.timestamp + VERIFICATION_TIMEOUT);
    }

    function claimVerificationRefund(uint256 playerId) external whenRegistryNotPaused {
        address club = playerRegistry.currentClub(playerId);
        if (msg.sender != club) revert CallerIsNotPlayerClub(playerId, msg.sender);

        IPlayerRegistry.VerificationRequest storage req = _verificationRequests[playerId];
        if (!req.active) revert NoActiveVerificationRequest(playerId);

        uint256 pausedSince    = playerRegistry.totalPausedDuration() - req.pauseSnapshot;
        uint256 adjustedDeadline = req.deadline + pausedSince;
        if (block.timestamp <= adjustedDeadline)
            revert VerificationDeadlineNotPassed(playerId, adjustedDeadline, block.timestamp);

        uint256 refund = req.feePaid;
        req.active  = false;
        req.feePaid = 0;

        playerRegistry.setVerificationActive(playerId, false);
        if (refund > 0) playerRegistry.EURC().safeTransfer(msg.sender, refund);

        emit VerificationRefundClaimed(playerId, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // REGISTRAR — Verification sign-off
    // ═══════════════════════════════════════════════════════════════════════════

    function verifyMedicalClearance(uint256 playerId) external whenRegistryNotPaused {
        _assertAssignedRegistrar(playerId);
        if (!_verificationRequests[playerId].active)        revert NoActiveVerificationRequest(playerId);
        if (!playerRegistry.getPlayer(playerId).medicalClearance) revert MedicalNotSubmitted(playerId);
        playerRegistry.setMedicalVerified(playerId, msg.sender);
    }

    function verifyLegalDocuments(uint256 playerId) external whenRegistryNotPaused {
        _assertAssignedRegistrar(playerId);
        if (!_verificationRequests[playerId].active) revert NoActiveVerificationRequest(playerId);
        if (playerRegistry.getLegalDocuments(playerId).registrationContractHash == bytes32(0))
            revert LegalDocsNotSubmitted(playerId);
        playerRegistry.setLegalDocsVerified(playerId, msg.sender);
    }

    function verifyPlayer(uint256 playerId) external whenRegistryNotPaused {
        _assertAssignedRegistrar(playerId);
        IPlayerRegistry.Player memory p = playerRegistry.getPlayer(playerId);
        if (p.isVerified)                                       revert PlayerAlreadyVerified(playerId);
        if (!_verificationRequests[playerId].active)            revert NoActiveVerificationRequest(playerId);
        if (!p.medicalVerified)                                 revert MedicalNotVerified(playerId);
        if (!playerRegistry.getLegalDocuments(playerId).documentsVerified) revert LegalDocsNotVerified(playerId);
        if (p.playerWallet == address(0))                       revert PlayerWalletNotSet(playerId);

        IPlayerRegistry.VerificationRequest storage req = _verificationRequests[playerId];
        uint256 fee = req.feePaid;
        req.active  = false;
        req.feePaid = 0;

        playerRegistry.setVerificationActive(playerId, false);
        playerRegistry.markPlayerVerified(playerId, msg.sender);
        _splitFee(fee, msg.sender);

        emit VerificationApproved(playerId, msg.sender);
    }

    function rejectVerification(uint256 playerId) external whenRegistryNotPaused {
        _assertAssignedRegistrar(playerId);
        if (!_verificationRequests[playerId].active) revert NoActiveVerificationRequest(playerId);

        IPlayerRegistry.VerificationRequest storage req = _verificationRequests[playerId];
        uint256 fee = req.feePaid;
        req.active  = false;
        req.feePaid = 0;

        playerRegistry.setVerificationActive(playerId, false);
        _splitFee(fee, msg.sender);

        emit VerificationRejected(playerId, msg.sender);
    }

    function resetPlayerWallet(uint256 playerId) external whenRegistryNotPaused {
        _assertAssignedRegistrar(playerId);
        playerRegistry.resetWallet(playerId, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW
    // ═══════════════════════════════════════════════════════════════════════════

    function getVerificationRequest(uint256 playerId)
        external view returns (IPlayerRegistry.VerificationRequest memory)
    {
        return _verificationRequests[playerId];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════════════════

    function _assertAssignedRegistrar(uint256 playerId) internal view {
        address club      = playerRegistry.currentClub(playerId);
        address registrar = playerRegistry.getClubRegistrar(club);
        if (registrar == address(0))   revert RegistrarNotAssignedToClub(club);
        if (registrar != msg.sender)   revert CallerIsNotAssignedRegistrar(playerId, msg.sender, registrar);
    }

    function _splitFee(uint256 fee, address registrar) internal {
        if (fee == 0) return;
        uint256 bps = playerRegistry.protocolFeeBps();
        uint256 protocolCut = (fee * bps + 9_999) / 10_000;
        if (protocolCut > fee) protocolCut = fee;
        uint256 registrarCut = fee - protocolCut;

        IERC20 eurc = playerRegistry.EURC();
        if (protocolCut > 0) {
            eurc.safeTransfer(address(playerRegistry), protocolCut);
            playerRegistry.addProtocolFees(protocolCut);
        }
        if (registrarCut > 0) {
            eurc.safeTransfer(address(playerRegistry), registrarCut);
            playerRegistry.addRegistrarFees(registrar, registrarCut);
        }
    }
}
