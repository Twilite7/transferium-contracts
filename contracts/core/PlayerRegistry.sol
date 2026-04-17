// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IPlayerRegistry.sol";

/**
 * @title PlayerRegistry
 * @author Transferium Protocol
 * @notice Manages player registration and transfer listings for professional football clubs.
 * @dev Security-first: role-based access control, pausability, and input validation on all state changes.
 *      Club ownership updates are triggered by the authorised TransferEscrow contract only.
 */
contract PlayerRegistry is IPlayerRegistry, AccessControl, Pausable, ReentrancyGuard {

    // ─── Roles ────────────────────────────────────────────────────────────────
    bytes32 public constant ADMIN_ROLE      = keccak256("ADMIN_ROLE");
    bytes32 public constant CLUB_ROLE       = keccak256("CLUB_ROLE");
    bytes32 public constant REGISTRAR_ROLE  = keccak256("REGISTRAR_ROLE");
    // I grant this role exclusively to the TransferEscrow contract address
    bytes32 public constant ESCROW_ROLE     = keccak256("ESCROW_ROLE");

    // ─── Constants ────────────────────────────────────────────────────────────
    uint256 public constant MAX_FEE        = 10_000 ether;
    uint256 public constant MAX_PRICE      = 500_000_000 ether;
    uint256 public constant MAX_STRING_LEN = 64;

    // ─── State ────────────────────────────────────────────────────────────────
    uint256 private _playerIdCounter;

    uint256 public registrationFee;
    uint256 public listingFee;

    // playerId => Player
    mapping(uint256 => Player) private _players;

    // club address => list of player IDs they own
    mapping(address => uint256[]) private _clubPlayers;

    // I track index of each player in their club's array for efficient removal
    mapping(uint256 => uint256) private _playerIndexInClub;

    // I use a hash of name + club to prevent duplicate registrations
    mapping(bytes32 => bool) private _playerExists;

    // ─── Events ───────────────────────────────────────────────────────────────
    event RegistrationFeeUpdated(uint256 oldFee, uint256 newFee);
    event ListingFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeesWithdrawn(address indexed to, uint256 amount);

    // ─── Errors ───────────────────────────────────────────────────────────────
    error InvalidString();
    error PlayerNotFound();
    error PlayerAlreadyExists();
    error PlayerAlreadyVerified();
    error PlayerNotVerified();
    error PlayerAlreadyListed();
    error PlayerNotListed();
    error NotPlayerClub();
    error InvalidPrice();
    error InvalidFee();
    error InvalidAddress();
    error InsufficientPayment();
    error ContractExpired();
    error WithdrawFailed();

    // ─── Constructor ──────────────────────────────────────────────────────────
    constructor(uint256 _registrationFee, uint256 _listingFee) {
        if (_registrationFee > MAX_FEE) revert InvalidFee();
        if (_listingFee > MAX_FEE) revert InvalidFee();

        registrationFee = _registrationFee;
        listingFee      = _listingFee;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(REGISTRAR_ROLE, msg.sender);
    }

    // ─── Modifiers ────────────────────────────────────────────────────────────
    modifier validString(string calldata s) {
        if (bytes(s).length == 0 || bytes(s).length > MAX_STRING_LEN) revert InvalidString();
        _;
    }

    modifier playerExists(uint256 playerId) {
        if (_players[playerId].registeredAt == 0) revert PlayerNotFound();
        _;
    }

    modifier onlyPlayerClub(uint256 playerId) {
        if (_players[playerId].currentClub != msg.sender) revert NotPlayerClub();
        _;
    }

    // ─── Club Functions ───────────────────────────────────────────────────────

    /**
     * @notice Register a new player. Caller must have CLUB_ROLE.
     */
    function registerPlayer(
        string calldata name,
        string calldata position,
        string calldata nationality,
        uint256 contractExpiry
    )
        external
        payable
        whenNotPaused
        nonReentrant
        onlyRole(CLUB_ROLE)
        validString(name)
        validString(position)
        validString(nationality)
        returns (uint256 playerId)
    {
        if (msg.value != registrationFee) revert InsufficientPayment();
        if (contractExpiry <= block.timestamp) revert ContractExpired();

        bytes32 playerHash = keccak256(abi.encodePacked(name, msg.sender));
        if (_playerExists[playerHash]) revert PlayerAlreadyExists();

        _playerIdCounter++;
        playerId = _playerIdCounter;

        _players[playerId] = Player({
            id:             playerId,
            name:           name,
            position:       position,
            nationality:    nationality,
            contractExpiry: contractExpiry,
            currentClub:    msg.sender,
            isVerified:     false,
            isListed:       false,
            askingPrice:    0,
            registeredAt:   block.timestamp
        });

        // I record the player's index in the club array before pushing
        _playerIndexInClub[playerId] = _clubPlayers[msg.sender].length;
        _clubPlayers[msg.sender].push(playerId);
        _playerExists[playerHash] = true;

        emit PlayerRegistered(playerId, name, msg.sender);
    }

    /**
     * @notice List a verified player for transfer.
     */
    function listPlayer(uint256 playerId, uint256 askingPrice)
        external
        payable
        whenNotPaused
        nonReentrant
        onlyRole(CLUB_ROLE)
        playerExists(playerId)
        onlyPlayerClub(playerId)
    {
        Player storage player = _players[playerId];

        if (!player.isVerified) revert PlayerNotVerified();
        if (player.isListed) revert PlayerAlreadyListed();
        if (askingPrice == 0 || askingPrice > MAX_PRICE) revert InvalidPrice();
        if (msg.value != listingFee) revert InsufficientPayment();
        if (player.contractExpiry <= block.timestamp) revert ContractExpired();

        player.isListed    = true;
        player.askingPrice = askingPrice;

        emit PlayerListed(playerId, askingPrice);
    }

    /**
     * @notice Delist a player from the transfer market.
     */
    function delistPlayer(uint256 playerId)
        external
        whenNotPaused
        nonReentrant
        onlyRole(CLUB_ROLE)
        playerExists(playerId)
        onlyPlayerClub(playerId)
    {
        Player storage player = _players[playerId];
        if (!player.isListed) revert PlayerNotListed();

        player.isListed    = false;
        player.askingPrice = 0;

        emit PlayerDelisted(playerId);
    }

    // ─── Registrar Functions ──────────────────────────────────────────────────

    /**
     * @notice Verify a player's eligibility. Only REGISTRAR_ROLE.
     */
    function verifyPlayer(uint256 playerId)
        external
        whenNotPaused
        onlyRole(REGISTRAR_ROLE)
        playerExists(playerId)
    {
        Player storage player = _players[playerId];
        if (player.isVerified) revert PlayerAlreadyVerified();

        player.isVerified = true;

        emit PlayerVerified(playerId, msg.sender);
    }

    // ─── Escrow Functions ─────────────────────────────────────────────────────

    /**
     * @notice Transfer club ownership of a player after a completed deal.
     * @dev Only callable by the TransferEscrow contract (ESCROW_ROLE).
     *      I update the club arrays, clear listing state, and emit the event.
     */
    function transferClubOwnership(uint256 playerId, address newClub)
        external
        override
        whenNotPaused
        nonReentrant
        onlyRole(ESCROW_ROLE)
        playerExists(playerId)
    {
        if (newClub == address(0)) revert InvalidAddress();

        Player storage player = _players[playerId];
        address oldClub = player.currentClub;

        if (oldClub == newClub) revert InvalidAddress();

        // I remove player from old club's array via swap-and-pop
        uint256 index   = _playerIndexInClub[playerId];
        uint256 lastId  = _clubPlayers[oldClub][_clubPlayers[oldClub].length - 1];
        _clubPlayers[oldClub][index] = lastId;
        _playerIndexInClub[lastId]   = index;
        _clubPlayers[oldClub].pop();

        // I add player to new club's array
        _playerIndexInClub[playerId] = _clubPlayers[newClub].length;
        _clubPlayers[newClub].push(playerId);

        // I clear listing state — player is no longer for sale after transfer
        player.currentClub = newClub;
        player.isListed    = false;
        player.askingPrice = 0;

        emit ClubOwnershipTransferred(playerId, oldClub, newClub);
    }

    // ─── Admin Functions ──────────────────────────────────────────────────────

    function setRegistrationFee(uint256 newFee) external onlyRole(ADMIN_ROLE) {
        if (newFee > MAX_FEE) revert InvalidFee();
        emit RegistrationFeeUpdated(registrationFee, newFee);
        registrationFee = newFee;
    }

    function setListingFee(uint256 newFee) external onlyRole(ADMIN_ROLE) {
        if (newFee > MAX_FEE) revert InvalidFee();
        emit ListingFeeUpdated(listingFee, newFee);
        listingFee = newFee;
    }

    function withdrawFees(address payable to) external nonReentrant onlyRole(ADMIN_ROLE) {
        if (to == address(0)) revert InvalidAddress();
        uint256 balance = address(this).balance;
        (bool success, ) = to.call{value: balance}("");
        if (!success) revert WithdrawFailed();
        emit FeesWithdrawn(to, balance);
    }

    function pause() external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    // ─── Views ────────────────────────────────────────────────────────────────

    function getPlayer(uint256 playerId)
        external
        view
        override
        playerExists(playerId)
        returns (Player memory)
    {
        return _players[playerId];
    }

    function getClubPlayers(address club)
        external
        view
        override
        returns (uint256[] memory)
    {
        return _clubPlayers[club];
    }

    function totalPlayers() external view override returns (uint256) {
        return _playerIdCounter;
    }
}
