// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IPlayerRegistry.sol";

interface IPlayerRegistryForTermination {
    function getPlayer(uint256 playerId)      external view returns (IPlayerRegistry.Player memory);
    function currentClub(uint256 playerId)    external view returns (address);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function paused()                         external view returns (bool);
    function totalPausedDuration()            external view returns (uint256);
    function CLUB_ROLE()                      external view returns (bytes32);
    function LEAGUE_ROLE()                    external view returns (bytes32);
    function burnPlayer(uint256 playerId)     external;
}

/**
 * @title  TerminationManager
 * @author Transferium Protocol
 * @notice Manages mutual and unilateral player contract termination.
 * @dev    Must be granted ESCROW_ROLE on PlayerRegistry (to call burnPlayer).
 *         PlayerRegistry must have this contract set as terminationManager
 *         so escrowTransfer can call clearTermination when a player moves clubs.
 *
 *         Mutual termination:
 *           1. Club calls proposeMutualTermination.
 *           2. Player wallet calls confirmMutualTermination → NFT burned.
 *
 *         Unilateral termination:
 *           1. Club (player must be delisted) or player wallet calls
 *              proposeUnilateralTermination with a reason string.
 *           2. Opposing party has 7 days to call disputeTermination.
 *           3a. No dispute → anyone calls executeTermination → NFT burned.
 *           3b. Disputed → LEAGUE_ROLE calls forceTerminate or rejectTermination.
 *
 *         Transfer interaction:
 *           If a player is transferred while any termination is pending,
 *           PlayerRegistry calls clearTermination, voiding the proposal.
 *           Transfer activity is never frozen by a pending termination.
 *
 *         Wage compensation is handled entirely off-chain.
 */
contract TerminationManager is ReentrancyGuard {

    // ─── Constants ────────────────────────────────────────────────────────────

    uint256 public constant DISPUTE_WINDOW = 7 days;

    // ─── State ────────────────────────────────────────────────────────────────

    IPlayerRegistryForTermination public immutable playerRegistry;

    mapping(uint256 => IPlayerRegistry.TerminationProposal) private _proposals;

    // ─── Events ───────────────────────────────────────────────────────────────

    event MutualTerminationProposed(uint256 indexed playerId, address indexed club);
    event MutualTerminationConfirmed(uint256 indexed playerId, address indexed playerWallet);
    event UnilateralTerminationProposed(
        uint256 indexed playerId,
        IPlayerRegistry.TerminationInitiator initiator,
        string  reason,
        uint256 disputeDeadline
    );
    event TerminationDisputed(uint256 indexed playerId, address indexed disputer);
    event TerminationExecuted(uint256 indexed playerId, address indexed executor);
    event TerminationForced(uint256 indexed playerId, address indexed league);
    event TerminationRejected(uint256 indexed playerId, address indexed league);
    event TerminationCleared(uint256 indexed playerId);
    event MutualTerminationWithdrawn(uint256 indexed playerId, address indexed club);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error ZeroAddress();
    error RegistryPaused();
    error NotPlayerClub(uint256 playerId, address caller, address club);
    error NotPlayerWallet(uint256 playerId, address caller, address wallet);
    error NotLeagueRole(address caller);
    error NotPlayerRegistry(address caller);
    error PlayerWalletNotSet(uint256 playerId);
    error PlayerIsListed(uint256 playerId);
    error NoProposal(uint256 playerId);
    error ProposalAlreadyExists(uint256 playerId);
    error NotMutualProposal(uint256 playerId);
    error NotUnilateralProposal(uint256 playerId);
    error NotDisputedProposal(uint256 playerId);
    error CallerCannotDispute(uint256 playerId, address caller);
    error DisputeWindowOpen(uint256 playerId, uint256 adjustedDeadline, uint256 now_);
    error DisputeWindowClosed(uint256 playerId, uint256 adjustedDeadline, uint256 now_);

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier whenRegistryNotPaused() {
        if (playerRegistry.paused()) revert RegistryPaused();
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(address playerRegistry_) {
        if (playerRegistry_ == address(0)) revert ZeroAddress();
        playerRegistry = IPlayerRegistryForTermination(playerRegistry_);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MUTUAL TERMINATION
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Club proposes mutual termination of a player's contract.
     *         Player must be delisted before this can be called.
     *         Player wallet must be set so they can confirm.
     */
    function proposeMutualTermination(uint256 playerId)
        external
        whenRegistryNotPaused
    {
        address club = playerRegistry.currentClub(playerId);
        if (msg.sender != club) revert NotPlayerClub(playerId, msg.sender, club);
        if (!playerRegistry.hasRole(playerRegistry.CLUB_ROLE(), msg.sender))
            revert NotPlayerClub(playerId, msg.sender, club);

        if (_proposals[playerId].state != IPlayerRegistry.TerminationState.None)
            revert ProposalAlreadyExists(playerId);

        IPlayerRegistry.Player memory p = playerRegistry.getPlayer(playerId);
        if (p.playerWallet == address(0)) revert PlayerWalletNotSet(playerId);
        if (p.isListed)                   revert PlayerIsListed(playerId);

        // EFFECTS
        _proposals[playerId] = IPlayerRegistry.TerminationProposal({
            initiator:       IPlayerRegistry.TerminationInitiator.Club,
            state:           IPlayerRegistry.TerminationState.Proposed,
            reason:          "Mutual termination",
            disputeDeadline: 0,
            pauseSnapshot:   0
        });

        emit MutualTerminationProposed(playerId, msg.sender);
    }

    /**
     * @notice Club withdraws its own mutual termination proposal.
     * @dev Without this, a club that proposes mutual termination — even by mistake —
     *      is permanently blocked from any further termination action because
     *      ProposalAlreadyExists fires on every subsequent attempt. The only
     *      existing escape (transfer the player) defeats the purpose of termination.
     *      Only the proposing club (current NFT holder) may withdraw.
     */
    function withdrawMutualTermination(uint256 playerId)
        external
        whenRegistryNotPaused
    {
        IPlayerRegistry.TerminationProposal storage prop = _proposals[playerId];
        if (prop.state != IPlayerRegistry.TerminationState.Proposed)
            revert NoProposal(playerId);
        if (prop.initiator != IPlayerRegistry.TerminationInitiator.Club)
            revert NotMutualProposal(playerId);

        address club = playerRegistry.currentClub(playerId);
        if (msg.sender != club) revert NotPlayerClub(playerId, msg.sender, club);

        // EFFECTS — clear before any external reads can observe stale state.
        delete _proposals[playerId];

        emit MutualTerminationWithdrawn(playerId, msg.sender);
    }

    /**
     * @notice Player wallet confirms the club's mutual termination proposal.
     *         NFT is burned and the player is freed from the registry.
     */
    function confirmMutualTermination(uint256 playerId)
        external
        whenRegistryNotPaused
        nonReentrant
    {
        IPlayerRegistry.TerminationProposal storage prop = _proposals[playerId];

        if (prop.state != IPlayerRegistry.TerminationState.Proposed)
            revert NoProposal(playerId);
        if (prop.initiator != IPlayerRegistry.TerminationInitiator.Club)
            revert NotMutualProposal(playerId);

        IPlayerRegistry.Player memory p = playerRegistry.getPlayer(playerId);
        if (msg.sender != p.playerWallet)
            revert NotPlayerWallet(playerId, msg.sender, p.playerWallet);

        // EFFECTS — clear before burn.
        delete _proposals[playerId];

        // INTERACTIONS
        playerRegistry.burnPlayer(playerId);

        emit MutualTerminationConfirmed(playerId, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // UNILATERAL TERMINATION
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Propose unilateral termination of a player's contract.
     *
     *         Club initiating: player must be delisted first.
     *         Player initiating: no listing restriction — the player has the
     *         right to propose regardless of their transfer status.
     *
     * @param playerId  Token ID of the player.
     * @param reason    Off-chain reason string stored on-chain for transparency.
     */
    function proposeUnilateralTermination(uint256 playerId, string calldata reason)
        external
        whenRegistryNotPaused
    {
        if (_proposals[playerId].state != IPlayerRegistry.TerminationState.None)
            revert ProposalAlreadyExists(playerId);

        IPlayerRegistry.Player memory p = playerRegistry.getPlayer(playerId);
        if (p.playerWallet == address(0)) revert PlayerWalletNotSet(playerId);

        address club = playerRegistry.currentClub(playerId);
        IPlayerRegistry.TerminationInitiator initiator;

        if (msg.sender == club && playerRegistry.hasRole(playerRegistry.CLUB_ROLE(), msg.sender)) {
            // I require the club to delist the player before proposing termination.
            if (p.isListed) revert PlayerIsListed(playerId);
            initiator = IPlayerRegistry.TerminationInitiator.Club;
        } else if (msg.sender == p.playerWallet) {
            // I allow the player to propose regardless of listing status.
            initiator = IPlayerRegistry.TerminationInitiator.Player;
        } else {
            // I revert with the most helpful error for the caller.
            if (p.playerWallet != address(0) && msg.sender != p.playerWallet)
                revert NotPlayerWallet(playerId, msg.sender, p.playerWallet);
            revert NotPlayerClub(playerId, msg.sender, club);
        }

        uint256 snapshot        = playerRegistry.totalPausedDuration();
        uint256 disputeDeadline = block.timestamp + DISPUTE_WINDOW;

        // EFFECTS
        _proposals[playerId] = IPlayerRegistry.TerminationProposal({
            initiator:       initiator,
            state:           IPlayerRegistry.TerminationState.Proposed,
            reason:          reason,
            disputeDeadline: disputeDeadline,
            pauseSnapshot:   snapshot
        });

        emit UnilateralTerminationProposed(playerId, initiator, reason, disputeDeadline);
    }

    /**
     * @notice Opposing party disputes the unilateral termination.
     *         Must be called within the 7-day dispute window.
     *         Disputed proposals escalate to LEAGUE_ROLE arbitration.
     */
    function disputeTermination(uint256 playerId)
        external
        whenRegistryNotPaused
    {
        IPlayerRegistry.TerminationProposal storage prop = _proposals[playerId];

        if (prop.state != IPlayerRegistry.TerminationState.Proposed)
            revert NoProposal(playerId);
        if (prop.initiator == IPlayerRegistry.TerminationInitiator.Club &&
            prop.disputeDeadline == 0)
            revert NotUnilateralProposal(playerId);

        // I check the caller is the opposing party.
        _assertOpposingParty(playerId, prop);

        // I check we are still inside the dispute window (pause-adjusted).
        uint256 pausedSince = playerRegistry.totalPausedDuration() - prop.pauseSnapshot;
        uint256 deadline_   = prop.disputeDeadline + pausedSince;
        if (block.timestamp > deadline_)
            revert DisputeWindowClosed(playerId, deadline_, block.timestamp);

        // EFFECTS
        prop.state = IPlayerRegistry.TerminationState.Disputed;

        emit TerminationDisputed(playerId, msg.sender);
    }

    /**
     * @notice Execute an undisputed termination after the 7-day window has passed.
     *         Anyone may call this — it is permissionless once the deadline is reached.
     */
    function executeTermination(uint256 playerId)
        external
        whenRegistryNotPaused
        nonReentrant
    {
        IPlayerRegistry.TerminationProposal storage prop = _proposals[playerId];

        if (prop.state != IPlayerRegistry.TerminationState.Proposed)
            revert NoProposal(playerId);
        if (prop.disputeDeadline == 0)
            revert NotUnilateralProposal(playerId);

        // I confirm the dispute window is fully elapsed (pause-adjusted).
        uint256 pausedSince = playerRegistry.totalPausedDuration() - prop.pauseSnapshot;
        uint256 deadline_   = prop.disputeDeadline + pausedSince;
        if (block.timestamp <= deadline_)
            revert DisputeWindowOpen(playerId, deadline_, block.timestamp);

        // EFFECTS
        delete _proposals[playerId];

        // INTERACTIONS
        playerRegistry.burnPlayer(playerId);

        emit TerminationExecuted(playerId, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LEAGUE — Arbitration
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice League approves the disputed termination. NFT is burned.
     */
    function forceTerminate(uint256 playerId)
        external
        whenRegistryNotPaused
        nonReentrant
    {
        if (!playerRegistry.hasRole(playerRegistry.LEAGUE_ROLE(), msg.sender))
            revert NotLeagueRole(msg.sender);

        IPlayerRegistry.TerminationProposal storage prop = _proposals[playerId];
        if (prop.state != IPlayerRegistry.TerminationState.Disputed)
            revert NotDisputedProposal(playerId);

        // EFFECTS
        delete _proposals[playerId];

        // INTERACTIONS
        playerRegistry.burnPlayer(playerId);

        emit TerminationForced(playerId, msg.sender);
    }

    /**
     * @notice League rejects the disputed termination. Player remains registered.
     *         The proposal is cleared and both parties may resume normal activity.
     */
    function rejectTermination(uint256 playerId)
        external
        whenRegistryNotPaused
    {
        if (!playerRegistry.hasRole(playerRegistry.LEAGUE_ROLE(), msg.sender))
            revert NotLeagueRole(msg.sender);

        IPlayerRegistry.TerminationProposal storage prop = _proposals[playerId];
        if (prop.state != IPlayerRegistry.TerminationState.Disputed)
            revert NotDisputedProposal(playerId);

        // EFFECTS
        delete _proposals[playerId];

        emit TerminationRejected(playerId, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PLAYERREGISTRY CALLBACK
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Called by PlayerRegistry during escrowTransfer to void any pending
     *         termination proposal when a player changes clubs.
     * @dev    Restricted to address(playerRegistry) only.
     */
    function clearTermination(uint256 playerId) external {
        if (msg.sender != address(playerRegistry))
            revert NotPlayerRegistry(msg.sender);
        if (_proposals[playerId].state != IPlayerRegistry.TerminationState.None) {
            delete _proposals[playerId];
            emit TerminationCleared(playerId);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW
    // ═══════════════════════════════════════════════════════════════════════════

    function getProposal(uint256 playerId)
        external view
        returns (IPlayerRegistry.TerminationProposal memory)
    {
        return _proposals[playerId];
    }

    /**
     * @notice Returns the pause-adjusted dispute deadline for an active proposal.
     *         Returns 0 if there is no proposal or it has no dispute window.
     */
    function adjustedDisputeDeadline(uint256 playerId) external view returns (uint256) {
        IPlayerRegistry.TerminationProposal storage prop = _proposals[playerId];
        if (prop.state == IPlayerRegistry.TerminationState.None) return 0;
        if (prop.disputeDeadline == 0) return 0;
        uint256 pausedSince = playerRegistry.totalPausedDuration() - prop.pauseSnapshot;
        return prop.disputeDeadline + pausedSince;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Asserts the caller is the party opposing the termination initiator.
     *         Club initiated → only player wallet can dispute.
     *         Player initiated → only current club can dispute.
     */
    function _assertOpposingParty(
        uint256 playerId,
        IPlayerRegistry.TerminationProposal storage prop
    ) internal view {
        IPlayerRegistry.Player memory p = playerRegistry.getPlayer(playerId);

        if (prop.initiator == IPlayerRegistry.TerminationInitiator.Club) {
            if (msg.sender != p.playerWallet)
                revert CallerCannotDispute(playerId, msg.sender);
        } else {
            address club = playerRegistry.currentClub(playerId);
            if (msg.sender != club)
                revert CallerCannotDispute(playerId, msg.sender);
        }
    }
}
