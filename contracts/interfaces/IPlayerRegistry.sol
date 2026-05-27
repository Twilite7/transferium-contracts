// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title  IPlayerRegistry
 * @author Transferium Protocol
 * @notice Interface for PlayerRegistry — used by escrow contracts.
 * @dev    Players are ERC-721 tokens. Ownership = club registration.
 *         Direct transfers are blocked — all transfers must go through escrow.
 */
interface IPlayerRegistry {

    // ─── Enums ────────────────────────────────────────────────────────────────

    enum TerminationState     { None, Proposed, Disputed, Executed }
    enum TerminationInitiator { None, Club, Player }

    // ─── Structs ──────────────────────────────────────────────────────────────

    struct Player {
        uint256 id;
        string  name;
        string  position;
        string  nationality;
        uint256 weeklySalary;        // EURC units (6 decimals), transparency only
        uint256 askingPrice;
        uint256 releaseClause;
        bytes32 medicalDocumentHash;
        bytes32 fifaId;              // keccak256(FIFA ID) — globally unique, mandatory
        address playerWallet;        // player's own wallet
        uint40  contractExpiry;      // safe until year 36,812
        uint40  registeredAt;
        bool    isVerified;
        bool    isListed;
        bool    medicalClearance;    // club submitted medical hash
        bool    medicalVerified;     // registrar signed off on medical
        string  portraitCID;
    }

    struct LegalDocuments {
        bytes32 registrationContractHash;
        bytes32 fifaTMSHash;
        bytes32 workPermitHash;      // bytes32(0) for domestic transfers
        bool    documentsVerified;
    }

    struct VerificationRequest {
        uint256 feePaid;             // EURC amount locked at time of request
        uint256 deadline;            // block.timestamp + 72h at time of request
        uint256 pauseSnapshot;       // _totalPausedDuration at time of request
        bool    active;
    }

    struct WalletUpdateRequest {
        address newWallet;
        uint256 executable;          // block.timestamp + 48h at time of request
        uint256 pauseSnapshot;       // _totalPausedDuration at time of request
        bool    active;
    }

    struct TerminationProposal {
        TerminationInitiator initiator;
        TerminationState     state;
        string               reason;
        uint256              disputeDeadline; // block.timestamp + 7d at time of proposal
        uint256              pauseSnapshot;   // _totalPausedDuration at time of proposal
    }

    // ─── Events ───────────────────────────────────────────────────────────────

    // Club management
    event ClubRegistered(address indexed club, string name, address indexed registrar);
    event ClubDeregistered(address indexed club);

    // Registrar management
    event RegistrarRoleGranted(address indexed registrar);
    event RegistrarRoleRevoked(address indexed registrar);

    // Player lifecycle
    event PlayerRegistered(uint256 indexed playerId, string name, address indexed club);
    event PlayerVerified(uint256 indexed playerId, address indexed registrar);
    event PlayerBurned(uint256 indexed playerId);

    // Medical
    event MedicalClearanceSet(uint256 indexed playerId, bytes32 documentHash);
    event MedicalClearanceVerified(uint256 indexed playerId, address indexed registrar);

    // Legal documents
    event LegalDocumentsSubmitted(uint256 indexed playerId);
    event LegalDocumentsVerified(uint256 indexed playerId, address indexed registrar);

    // Verification flow
    event VerificationRequested(uint256 indexed playerId, address indexed club, uint256 feePaid, uint256 deadline);
    event VerificationApproved(uint256 indexed playerId, address indexed registrar);
    event VerificationRejected(uint256 indexed playerId, address indexed registrar);
    event VerificationRefundClaimed(uint256 indexed playerId, address indexed club);

    // Player wallet
    event PlayerWalletSet(uint256 indexed playerId, address indexed playerWallet);
    event WalletUpdateInitiated(uint256 indexed playerId, address indexed newWallet, uint256 executable);
    event WalletUpdateCancelled(uint256 indexed playerId);
    event WalletUpdateExecuted(uint256 indexed playerId, address indexed oldWallet, address indexed newWallet);
    event PlayerWalletReset(uint256 indexed playerId, address indexed registrar);

    // Transfer listing
    event PlayerListed(uint256 indexed playerId, uint256 askingPrice);
    event PlayerDelisted(uint256 indexed playerId);
    event ReleaseClauseSet(uint256 indexed playerId, uint256 amount);
    event ContractExtended(uint256 indexed playerId, uint256 newExpiry);
    event ClubOwnershipTransferred(uint256 indexed playerId, address indexed fromClub, address indexed toClub);

    // Termination
    event MutualTerminationProposed(uint256 indexed playerId, address indexed club);
    event MutualTerminationConfirmed(uint256 indexed playerId);
    event UnilateralTerminationProposed(uint256 indexed playerId, TerminationInitiator initiator, string reason, uint256 disputeDeadline);
    event TerminationDisputed(uint256 indexed playerId, address indexed disputer);
    event TerminationExecuted(uint256 indexed playerId);
    event TerminationForced(uint256 indexed playerId, address indexed league);
    event TerminationRejected(uint256 indexed playerId, address indexed league);

    // Fees & treasury
    event BaseVerificationFeeScheduled(uint256 newFee, uint256 effectiveAt);
    event BaseVerificationFeeActivated(uint256 newFee);
    event VerificationFeeSet(address indexed registrar, uint256 fee);
    event ProtocolFeeBpsSet(uint256 bps);
    event RegistrationFeeSet(uint256 fee);
    event ListingFeeSet(uint256 fee);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event RegistrarFeesWithdrawn(address indexed registrar, uint256 amount);
    event ProtocolTreasuryUpdateScheduled(address indexed newTreasury, uint256 effectiveAt);
    event ProtocolTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    // ─── View functions ───────────────────────────────────────────────────────

    function getPlayer(uint256 playerId)         external view returns (Player memory);
    function getLegalDocuments(uint256 playerId) external view returns (LegalDocuments memory);
    function getClubPlayers(address club)        external view returns (uint256[] memory);
    function totalPlayers()                      external view returns (uint256);
    function currentClub(uint256 playerId)       external view returns (address);
    function hasClubRole(address account)        external view returns (bool);
    function getClubRegistrar(address club)      external view returns (address);


    // ─── Escrow-callable ──────────────────────────────────────────────────────

    function escrowTransfer(uint256 playerId, address fromClub, address toClub) external;
    function burnPlayer(uint256 playerId) external;
}
