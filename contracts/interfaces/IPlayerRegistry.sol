// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IPlayerRegistry
 * @author Transferium Protocol
 * @notice Interface for PlayerRegistry — used by TransferEscrow to update club ownership
 *         after a deal completes.
 */
interface IPlayerRegistry {

    // ─── Structs ──────────────────────────────────────────────────────────────
    struct Player {
        uint256 id;
        string  name;
        string  position;
        string  nationality;
        uint256 contractExpiry;
        address currentClub;
        bool    isVerified;
        bool    isListed;
        uint256 askingPrice;
        uint256 registeredAt;
    }

    // ─── Events ───────────────────────────────────────────────────────────────
    event PlayerRegistered(uint256 indexed playerId, string name, address indexed club);
    event PlayerVerified(uint256 indexed playerId, address indexed registrar);
    event PlayerListed(uint256 indexed playerId, uint256 askingPrice);
    event PlayerDelisted(uint256 indexed playerId);
    event ClubOwnershipTransferred(uint256 indexed playerId, address indexed fromClub, address indexed toClub);

    // ─── Functions ────────────────────────────────────────────────────────────
    function getPlayer(uint256 playerId) external view returns (Player memory);
    function getClubPlayers(address club) external view returns (uint256[] memory);
    function totalPlayers() external view returns (uint256);

    /**
     * @notice Called by TransferEscrow upon deal completion to transfer
     *         on-chain club ownership of a player.
     * @dev Only callable by the authorised escrow contract address.
     */
    function transferClubOwnership(uint256 playerId, address newClub) external;
}
