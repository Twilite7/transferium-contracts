// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../interfaces/IPlayerRegistry.sol";

interface IPlayerRegistryForTermination {
    function currentClub(uint256 playerId) external view returns (address);
    function hasClubRole(address account) external view returns (bool);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function getPlayer(uint256 playerId) external view returns (IPlayerRegistry.Player memory);
    function burnPlayer(uint256 playerId) external;
    function paused() external view returns (bool);
    function totalPausedDuration() external view returns (uint256);
}

/**
 * @title  TerminationManager
 * @author Transferium Protocol
 * @notice Manages mutual and unilateral contract termination for player NFTs.
 * @dev    Extracted from PlayerRegistry to keep it under the 24,576-byte limit.
 *         Holds its own termination state. Must be granted ESCROW_ROLE on
 *         PlayerRegistry before use, so it can call burnPlayer().
 */
contract TerminationManager {

    // ─── Constants ────────────────────────────────────────────────────────────

    uint256 public constant TERMINATION_DISPUTE_WINDOW = 7 days;
    uint256 public constant MAX_REASON_LENGTH          = 256;
    bytes32 public constant LEAGUE_ROLE                = keccak256("LEAGUE_ROLE");
    bytes32 public constant ESCROW_ROLE                = keccak256("ESCROW_ROLE");

    // ─── State ────────────────────────────────────────────────────────────────

    IPlayerRegistryForTermination public playerRegistry;
    address public admin;

    mapping(uint256 => bool)                                private _mutualTerminationProposed;
    mapping(uint256 => IPlayerRegistry.TerminationProposal) private _terminationProposals;

    // ─── Events ───────────────────────────────────────────────────────────────

    event MutualTerminationProposed(uint256 indexed playerId, address proposer);
    event MutualTerminationConfirmed(uint256 indexed playerId);
    event UnilateralTerminationProposed(uint256 indexed playerId, IPlayerRegistry.TerminationInitiator initiator, string reason, uint256 disputeDeadline);
    event TerminationDisputed(uint256 indexed playerId, address disputer);
    event TerminationExecuted(uint256 indexed playerId);
    event TerminationForced(uint256 indexed playerId, address league);
    event TerminationRejected(uint256 indexed playerId, address league);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error ZeroAddress();
    error NotAdmin();
    error NotEscrow();
    error RegistryPaused();
    error CallerIsNotPlayerClub(uint256 playerId, address caller);
    error CallerIsNotPlayerWallet(uint256 playerId, address caller);
    error CallerIsNotClubOrPlayerWallet(uint256 playerId, address caller);
    error CallerIsNotLeague(address caller);
    error MutualTerminationNotProposed(uint256 playerId);
    error MutualTerminationAlreadyProposed(uint256 playerId);
    error TerminationAlreadyProposed(uint256 playerId);
    error NoTerminationProposal(uint256 playerId);
    error TerminationAlreadyDisputed(uint256 playerId);
    error TerminationDisputeWindowStillOpen(uint256 playerId, uint256 adjustedDeadline, uint256 now_);
    error TerminationDisputeWindowClosed(uint256 playerId, uint256 adjustedDeadline, uint256 now_);
    error TerminationNotDisputed(uint256 playerId);
    error TerminationAlreadyExecuted(uint256 playerId);
    error EmptyString();
    error ReasonTooLong(uint256 length, uint256 max);

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
        playerRegistry = IPlayerRegistryForTermination(registry_);
        admin          = admin_;
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        admin = newAdmin;
    }

    /**
     * @notice Clear termination state for a player.
     * @dev    Called by PlayerRegistry on escrow transfer or external burn.
     *         Caller must hold ESCROW_ROLE on PlayerRegistry.
     */
    function clearTermination(uint256 playerId) external {
        if (!playerRegistry.hasRole(ESCROW_ROLE, msg.sender)) revert NotEscrow();
        delete _mutualTerminationProposed[playerId];
        delete _terminationProposals[playerId];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TERMINATION — Mutual
    // ═══════════════════════════════════════════════════════════════════════════

    function proposeMutualTermination(uint256 playerId) external whenRegistryNotPaused {
        if (!playerRegistry.hasClubRole(msg.sender))
            revert CallerIsNotPlayerClub(playerId, msg.sender);
        if (playerRegistry.currentClub(playerId) != msg.sender)
            revert CallerIsNotPlayerClub(playerId, msg.sender);
        if (_mutualTerminationProposed[playerId])
            revert MutualTerminationAlreadyProposed(playerId);
        if (_terminationProposals[playerId].state != IPlayerRegistry.TerminationState.None)
            revert TerminationAlreadyProposed(playerId);

        _mutualTerminationProposed[playerId] = true;
        emit MutualTerminationProposed(playerId, msg.sender);
    }

    function confirmMutualTermination(uint256 playerId) external whenRegistryNotPaused {
        IPlayerRegistry.Player memory p = playerRegistry.getPlayer(playerId);
        if (p.playerWallet != msg.sender)
            revert CallerIsNotPlayerWallet(playerId, msg.sender);
        if (!_mutualTerminationProposed[playerId])
            revert MutualTerminationNotProposed(playerId);

        delete _mutualTerminationProposed[playerId];
        delete _terminationProposals[playerId];
        playerRegistry.burnPlayer(playerId);

        emit MutualTerminationConfirmed(playerId);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TERMINATION — Unilateral
    // ═══════════════════════════════════════════════════════════════════════════

    function proposeUnilateralTermination(uint256 playerId, string calldata reason)
        external whenRegistryNotPaused
    {
        if (bytes(reason).length == 0)                revert EmptyString();
        if (bytes(reason).length > MAX_REASON_LENGTH) revert ReasonTooLong(bytes(reason).length, MAX_REASON_LENGTH);

        address club         = playerRegistry.currentClub(playerId);
        address playerWallet = playerRegistry.getPlayer(playerId).playerWallet;

        bool isClub   = (msg.sender == club)         && playerRegistry.hasClubRole(msg.sender);
        bool isPlayer = (msg.sender == playerWallet) && (playerWallet != address(0));

        if (!isClub && !isPlayer)
            revert CallerIsNotClubOrPlayerWallet(playerId, msg.sender);
        if (_mutualTerminationProposed[playerId])
            revert MutualTerminationAlreadyProposed(playerId);
        if (_terminationProposals[playerId].state != IPlayerRegistry.TerminationState.None)
            revert TerminationAlreadyProposed(playerId);

        _terminationProposals[playerId] = IPlayerRegistry.TerminationProposal({
            initiator:       isClub ? IPlayerRegistry.TerminationInitiator.Club : IPlayerRegistry.TerminationInitiator.Player,
            state:           IPlayerRegistry.TerminationState.Proposed,
            reason:          reason,
            disputeDeadline: block.timestamp + TERMINATION_DISPUTE_WINDOW,
            pauseSnapshot:   playerRegistry.totalPausedDuration()
        });

        emit UnilateralTerminationProposed(
            playerId,
            isClub ? IPlayerRegistry.TerminationInitiator.Club : IPlayerRegistry.TerminationInitiator.Player,
            reason,
            block.timestamp + TERMINATION_DISPUTE_WINDOW
        );
    }

    function disputeTermination(uint256 playerId) external whenRegistryNotPaused {
        IPlayerRegistry.TerminationProposal storage proposal = _terminationProposals[playerId];
        if (proposal.state == IPlayerRegistry.TerminationState.None)
            revert NoTerminationProposal(playerId);
        if (proposal.state != IPlayerRegistry.TerminationState.Proposed)
            revert TerminationAlreadyDisputed(playerId);

        address club         = playerRegistry.currentClub(playerId);
        address playerWallet = playerRegistry.getPlayer(playerId).playerWallet;

        bool isOpposingParty =
            (proposal.initiator == IPlayerRegistry.TerminationInitiator.Club   && msg.sender == playerWallet) ||
            (proposal.initiator == IPlayerRegistry.TerminationInitiator.Player && msg.sender == club && playerRegistry.hasClubRole(msg.sender));

        if (!isOpposingParty)
            revert CallerIsNotClubOrPlayerWallet(playerId, msg.sender);

        uint256 pausedSince      = playerRegistry.totalPausedDuration() - proposal.pauseSnapshot;
        uint256 adjustedDeadline = proposal.disputeDeadline + pausedSince;

        if (block.timestamp > adjustedDeadline)
            revert TerminationDisputeWindowClosed(playerId, adjustedDeadline, block.timestamp);

        proposal.state = IPlayerRegistry.TerminationState.Disputed;
        emit TerminationDisputed(playerId, msg.sender);
    }

    function executeTermination(uint256 playerId) external whenRegistryNotPaused {
        IPlayerRegistry.TerminationProposal storage proposal = _terminationProposals[playerId];
        if (proposal.state == IPlayerRegistry.TerminationState.None)
            revert NoTerminationProposal(playerId);
        if (proposal.state == IPlayerRegistry.TerminationState.Disputed)
            revert TerminationAlreadyDisputed(playerId);
        if (proposal.state == IPlayerRegistry.TerminationState.Executed)
            revert TerminationAlreadyExecuted(playerId);

        uint256 pausedSince      = playerRegistry.totalPausedDuration() - proposal.pauseSnapshot;
        uint256 adjustedDeadline = proposal.disputeDeadline + pausedSince;

        if (block.timestamp <= adjustedDeadline)
            revert TerminationDisputeWindowStillOpen(playerId, adjustedDeadline, block.timestamp);

        proposal.state = IPlayerRegistry.TerminationState.Executed;
        delete _mutualTerminationProposed[playerId];
        playerRegistry.burnPlayer(playerId);

        emit TerminationExecuted(playerId);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LEAGUE — Termination arbitration
    // ═══════════════════════════════════════════════════════════════════════════

    function forceTerminate(uint256 playerId) external whenRegistryNotPaused {
        if (!playerRegistry.hasRole(LEAGUE_ROLE, msg.sender))
            revert CallerIsNotLeague(msg.sender);

        IPlayerRegistry.TerminationProposal storage proposal = _terminationProposals[playerId];
        if (proposal.state != IPlayerRegistry.TerminationState.Disputed)
            revert TerminationNotDisputed(playerId);

        proposal.state = IPlayerRegistry.TerminationState.Executed;
        delete _mutualTerminationProposed[playerId];
        playerRegistry.burnPlayer(playerId);

        emit TerminationForced(playerId, msg.sender);
    }

    function rejectTermination(uint256 playerId) external whenRegistryNotPaused {
        if (!playerRegistry.hasRole(LEAGUE_ROLE, msg.sender))
            revert CallerIsNotLeague(msg.sender);

        IPlayerRegistry.TerminationProposal storage proposal = _terminationProposals[playerId];
        if (proposal.state != IPlayerRegistry.TerminationState.Disputed)
            revert TerminationNotDisputed(playerId);

        delete _terminationProposals[playerId];
        emit TerminationRejected(playerId, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW
    // ═══════════════════════════════════════════════════════════════════════════

    function getTerminationProposal(uint256 playerId)
        external view returns (IPlayerRegistry.TerminationProposal memory)
    {
        return _terminationProposals[playerId];
    }

    function isMutualTerminationProposed(uint256 playerId) external view returns (bool) {
        return _mutualTerminationProposed[playerId];
    }
}
