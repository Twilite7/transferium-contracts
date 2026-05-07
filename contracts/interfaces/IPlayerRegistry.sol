// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IPlayerRegistry
 * @author Transferium Protocol
 * @notice Interface for PlayerRegistry — used by TransferEscrow and LoanEscrow.
 * @dev Players are ERC-721 tokens. Ownership = club registration.
 *      Direct transfers are blocked — all transfers must go through escrow contracts.
 */
interface IPlayerRegistry {

    // ─── Structs ──────────────────────────────────────────────────────────────
    struct Player {
        uint256 id;
        string  name;
        string  position;
        string  nationality;
        uint256 contractExpiry;
        uint256 weeklySalary;       // in EURC units (6 decimals), transparency only
        address playerWallet;       // player's own wallet — set by REGISTRAR_ROLE
        bool    isVerified;
        bool    isListed;
        bool    medicalClearance;
        bytes32 medicalDocumentHash;
        uint256 askingPrice;
        uint256 releaseClause;
        uint256 registeredAt;
        string  portraitCID;
    }

    struct LegalDocuments {
        bytes32 registrationContractHash; // player-club employment contract
        bytes32 identityDocumentHash;     // passport or national ID
        bytes32 fifaTMSHash;              // FIFA Transfer Matching System reference
        bytes32 workPermitHash;           // 0 if domestic transfer
        bool    documentsVerified;        // set by REGISTRAR_ROLE after review
    }

    // ─── Events ───────────────────────────────────────────────────────────────
    event PlayerRegistered(uint256 indexed playerId, string name, address indexed club);
    event PlayerVerified(uint256 indexed playerId, address indexed registrar);
    event MedicalClearanceSet(uint256 indexed playerId, bytes32 documentHash);
    event LegalDocumentsSubmitted(uint256 indexed playerId);
    event LegalDocumentsVerified(uint256 indexed playerId, address indexed registrar);
    event PlayerWalletSet(uint256 indexed playerId, address indexed playerWallet);
    event PlayerWalletUpdated(uint256 indexed playerId, address indexed oldWallet, address indexed newWallet);
    event PlayerListed(uint256 indexed playerId, uint256 askingPrice);
    event PlayerDelisted(uint256 indexed playerId);
    event ReleaseClauseSet(uint256 indexed playerId, uint256 amount);
    event ContractExtended(uint256 indexed playerId, uint256 newExpiry);
    event ClubOwnershipTransferred(uint256 indexed playerId, address indexed fromClub, address indexed toClub);

    // ─── Functions ────────────────────────────────────────────────────────────
    function getPlayer(uint256 playerId) external view returns (Player memory);
    function getLegalDocuments(uint256 playerId) external view returns (LegalDocuments memory);
    function getClubPlayers(address club) external view returns (uint256[] memory);
    function totalPlayers() external view returns (uint256);
    function currentClub(uint256 playerId) external view returns (address);
    function hasClubRole(address account) external view returns (bool);
    function escrowTransfer(uint256 playerId, address fromClub, address toClub) external;
}
