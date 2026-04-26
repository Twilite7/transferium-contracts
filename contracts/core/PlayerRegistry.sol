// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "../interfaces/IPlayerRegistry.sol";

/**
 * @title PlayerRegistry
 * @author Transferium Protocol
 * @notice ERC-721 player registration for professional football.
 *         Each player is an NFT. The token owner is the registered club.
 * @dev Security-first:
 *      - Direct ERC-721 transfers blocked — only ESCROW_ROLE can move tokens
 *      - Medical clearance + legal document verification required before listing
 *      - Player wallet set by registrar, updatable by player themselves
 *      - ESCROW_ROLE must be granted post-deployment to TransferEscrow and LoanEscrow
 */
contract PlayerRegistry is IPlayerRegistry, ERC721, AccessControl, Pausable, ReentrancyGuard {
    using Strings for uint256;

    // ─── Roles ────────────────────────────────────────────────────────────────
    bytes32 public constant ADMIN_ROLE     = keccak256("ADMIN_ROLE");
    bytes32 public constant CLUB_ROLE      = keccak256("CLUB_ROLE");
    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");
    bytes32 public constant ESCROW_ROLE    = keccak256("ESCROW_ROLE");

    // ─── Constants ────────────────────────────────────────────────────────────
    uint256 public constant MAX_FEE        = 10_000 ether;
    uint256 public constant MAX_PRICE      = 500_000_000 ether;
    uint256 public constant MAX_STRING_LEN = 64;
    uint256 public constant MAX_WITHDRAW   = 1_000 ether;
    uint256 public constant MAX_SALARY     = 10_000_000 ether; // 10M EURC weekly salary cap

    // ─── State ────────────────────────────────────────────────────────────────
    uint256 private _playerIdCounter;

    uint256 public registrationFee;
    uint256 public listingFee;

    mapping(uint256 => Player)          private _players;
    mapping(uint256 => LegalDocuments)  private _legalDocs;
    mapping(address => uint256[])       private _clubPlayers;
    mapping(uint256 => uint256)         private _playerIndexInClub;
    mapping(bytes32 => bool)            private _playerExists;
    mapping(bytes32 => bool)            private _usedDocumentHashes;

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
    error WithdrawAmountTooLarge();
    error InsufficientBalance();
    error DirectTransferBlocked();
    error MedicalClearanceRequired();
    error LegalDocsNotVerified();
    error InvalidExpiry();
    error MedicalAlreadyCleared();
    error DocumentsAlreadyVerified();
    error PlayerWalletNotSet();
    error NotPlayerWallet();
    error InvalidSalary();

    // ─── Constructor ──────────────────────────────────────────────────────────
    constructor(uint256 _registrationFee, uint256 _listingFee)
        ERC721("Transferium Player", "TPLYR")
    {
        if (_registrationFee > MAX_FEE) revert InvalidFee();
        if (_listingFee > MAX_FEE) revert InvalidFee();

        registrationFee = _registrationFee;
        listingFee      = _listingFee;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(REGISTRAR_ROLE, msg.sender);
    }

    // ─── ERC-721 Transfer Block ───────────────────────────────────────────────

    /**
     * @notice I block all direct ERC-721 transfers.
     * @dev Only ESCROW_ROLE contracts can move player tokens via escrowTransfer().
     */
    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address)
    {
        address from = _ownerOf(tokenId);
        if (from != address(0) && !hasRole(ESCROW_ROLE, msg.sender)) {
            revert DirectTransferBlocked();
        }
        return super._update(to, tokenId, auth);
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
        if (ownerOf(playerId) != msg.sender) revert NotPlayerClub();
        _;
    }

    // ─── Club Functions ───────────────────────────────────────────────────────

    /**
     * @notice Register a new player and mint their NFT to the registering club.
     * @dev weeklySalary is a transparency field — no actual payments happen here.
     */
    function registerPlayer(
        string calldata name,
        string calldata position,
        string calldata nationality,
        uint256 contractExpiry,
        uint256 weeklySalary
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
        if (weeklySalary > MAX_SALARY) revert InvalidSalary();

        bytes32 playerHash = keccak256(abi.encodePacked(name, msg.sender));
        if (_playerExists[playerHash]) revert PlayerAlreadyExists();

        _playerIdCounter++;
        playerId = _playerIdCounter;

        _players[playerId] = Player({
            id:                  playerId,
            name:                name,
            position:            position,
            nationality:         nationality,
            contractExpiry:      contractExpiry,
            weeklySalary:        weeklySalary,
            playerWallet:        address(0),
            isVerified:          false,
            isListed:            false,
            medicalClearance:    false,
            medicalDocumentHash: bytes32(0),
            askingPrice:         0,
            releaseClause:       0,
            registeredAt:        block.timestamp
        });

        _playerIndexInClub[playerId] = _clubPlayers[msg.sender].length;
        _clubPlayers[msg.sender].push(playerId);
        _playerExists[playerHash] = true;

        _mint(msg.sender, playerId);

        emit PlayerRegistered(playerId, name, msg.sender);
    }

    /**
     * @notice List a verified player for transfer.
     * @dev Requires: verified + medical clearance + legal docs verified.
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
        if (!player.medicalClearance) revert MedicalClearanceRequired();
        if (!_legalDocs[playerId].documentsVerified) revert LegalDocsNotVerified();
        if (player.isListed) revert PlayerAlreadyListed();
        if (askingPrice == 0 || askingPrice > MAX_PRICE) revert InvalidPrice();
        if (msg.value != listingFee) revert InsufficientPayment();
        if (player.contractExpiry <= block.timestamp) revert ContractExpired();

        player.isListed    = true;
        player.askingPrice = askingPrice;

        emit PlayerListed(playerId, askingPrice);
    }

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

    function setReleaseClause(uint256 playerId, uint256 amount)
        external
        whenNotPaused
        nonReentrant
        onlyRole(CLUB_ROLE)
        playerExists(playerId)
        onlyPlayerClub(playerId)
    {
        if (amount > MAX_PRICE) revert InvalidPrice();
        _players[playerId].releaseClause = amount;
        emit ReleaseClauseSet(playerId, amount);
    }

    function extendContract(uint256 playerId, uint256 newExpiry)
        external
        whenNotPaused
        nonReentrant
        onlyRole(CLUB_ROLE)
        playerExists(playerId)
        onlyPlayerClub(playerId)
    {
        if (newExpiry <= block.timestamp) revert InvalidExpiry();
        if (newExpiry <= _players[playerId].contractExpiry) revert InvalidExpiry();
        _players[playerId].contractExpiry = newExpiry;
        emit ContractExtended(playerId, newExpiry);
    }

    /**
     * @notice Club submits legal document hashes for a player.
     * @dev Documents live off-chain. Hashes are the on-chain proof.
     *      workPermitHash can be zero for domestic transfers.
     */
    function submitLegalDocuments(
        uint256 playerId,
        bytes32 registrationContractHash,
        bytes32 identityDocumentHash,
        bytes32 fifaTMSHash,
        bytes32 workPermitHash
    )
        external
        whenNotPaused
        nonReentrant
        onlyRole(CLUB_ROLE)
        playerExists(playerId)
        onlyPlayerClub(playerId)
    {
        if (registrationContractHash == bytes32(0)) revert InvalidAddress();
        if (identityDocumentHash == bytes32(0)) revert InvalidAddress();
        if (fifaTMSHash == bytes32(0)) revert InvalidAddress();
        if (_usedDocumentHashes[registrationContractHash]) revert InvalidAddress();
        if (_usedDocumentHashes[identityDocumentHash])     revert InvalidAddress();
        if (_usedDocumentHashes[fifaTMSHash])              revert InvalidAddress();
        if (workPermitHash != bytes32(0) && _usedDocumentHashes[workPermitHash]) revert InvalidAddress();

        _legalDocs[playerId] = LegalDocuments({
            registrationContractHash: registrationContractHash,
            identityDocumentHash:     identityDocumentHash,
            fifaTMSHash:              fifaTMSHash,
            workPermitHash:           workPermitHash,
            documentsVerified:        false
        });
        _usedDocumentHashes[registrationContractHash] = true;
        _usedDocumentHashes[identityDocumentHash]     = true;
        _usedDocumentHashes[fifaTMSHash]              = true;
        if (workPermitHash != bytes32(0)) _usedDocumentHashes[workPermitHash] = true;

        emit LegalDocumentsSubmitted(playerId);
    }

    // ─── Registrar Functions ──────────────────────────────────────────────────

    function verifyPlayer(uint256 playerId)
        external
        whenNotPaused
        onlyRole(REGISTRAR_ROLE)
        playerExists(playerId)
    {
        if (_players[playerId].isVerified) revert PlayerAlreadyVerified();
        _players[playerId].isVerified = true;
        emit PlayerVerified(playerId, msg.sender);
    }

    function setMedicalClearance(uint256 playerId, bytes32 documentHash)
        external
        whenNotPaused
        nonReentrant
        onlyRole(REGISTRAR_ROLE)
        playerExists(playerId)
    {
        if (documentHash == bytes32(0)) revert InvalidAddress();
        if (_usedDocumentHashes[documentHash]) revert InvalidAddress();
        if (_players[playerId].medicalClearance) revert MedicalAlreadyCleared();

        _players[playerId].medicalClearance    = true;
        _players[playerId].medicalDocumentHash = documentHash;
        _usedDocumentHashes[documentHash]      = true;

        emit MedicalClearanceSet(playerId, documentHash);
    }

    /**
     * @notice Registrar verifies submitted legal documents after off-chain review.
     */
    function verifyLegalDocuments(uint256 playerId)
        external
        whenNotPaused
        nonReentrant
        onlyRole(REGISTRAR_ROLE)
        playerExists(playerId)
    {
        LegalDocuments storage docs = _legalDocs[playerId];
        if (docs.documentsVerified) revert DocumentsAlreadyVerified();
        if (docs.registrationContractHash == bytes32(0)) revert InvalidAddress();

        docs.documentsVerified = true;

        emit LegalDocumentsVerified(playerId, msg.sender);
    }

    /**
     * @notice Registrar sets the player's own wallet address after identity verification.
     * @dev Once set, only the player themselves can update it via updatePlayerWallet().
     */
    function setPlayerWallet(uint256 playerId, address playerWallet)
        external
        whenNotPaused
        nonReentrant
        onlyRole(REGISTRAR_ROLE)
        playerExists(playerId)
    {
        if (playerWallet == address(0)) revert InvalidAddress();
        if (_players[playerId].playerWallet != address(0)) revert InvalidAddress();

        _players[playerId].playerWallet = playerWallet;

        emit PlayerWalletSet(playerId, playerWallet);
    }

    // ─── Player Functions ─────────────────────────────────────────────────────

    /**
     * @notice Player updates their own wallet address.
     * @dev Only callable from the currently registered playerWallet.
     *      This allows players to rotate wallets without club or registrar involvement.
     */
    function updatePlayerWallet(uint256 playerId, address newWallet)
        external
        whenNotPaused
        nonReentrant
        playerExists(playerId)
    {
        Player storage player = _players[playerId];
        if (player.playerWallet == address(0)) revert PlayerWalletNotSet();
        if (player.playerWallet != msg.sender) revert NotPlayerWallet();
        if (newWallet == address(0)) revert InvalidAddress();

        address oldWallet      = player.playerWallet;
        player.playerWallet    = newWallet;

        emit PlayerWalletUpdated(playerId, oldWallet, newWallet);
    }

    // ─── Escrow Functions ─────────────────────────────────────────────────────

    function escrowTransfer(uint256 playerId, address fromClub, address toClub)
        external
        override
        whenNotPaused
        nonReentrant
        onlyRole(ESCROW_ROLE)
        playerExists(playerId)
    {
        if (toClub == address(0)) revert InvalidAddress();
        if (fromClub == toClub) revert InvalidAddress();
        if (ownerOf(playerId) != fromClub) revert NotPlayerClub();

        // I remove from old club array via swap-and-pop
        uint256 index  = _playerIndexInClub[playerId];
        uint256 lastId = _clubPlayers[fromClub][_clubPlayers[fromClub].length - 1];
        _clubPlayers[fromClub][index] = lastId;
        _playerIndexInClub[lastId]    = index;
        _clubPlayers[fromClub].pop();

        // I add to new club array
        _playerIndexInClub[playerId] = _clubPlayers[toClub].length;
        _clubPlayers[toClub].push(playerId);

        // I clear listing, medical clearance and legal docs — fresh start at new club
        Player storage player        = _players[playerId];
        player.isListed              = false;
        player.askingPrice           = 0;
        player.medicalClearance      = false;
        player.medicalDocumentHash   = bytes32(0);

        // I reset legal documents — new club must submit fresh docs
        _legalDocs[playerId] = LegalDocuments({
            registrationContractHash: bytes32(0),
            identityDocumentHash:     bytes32(0),
            fifaTMSHash:              bytes32(0),
            workPermitHash:           bytes32(0),
            documentsVerified:        false
        });

        _transfer(fromClub, toClub, playerId);

        emit ClubOwnershipTransferred(playerId, fromClub, toClub);
    }

    // ─── Token URI ────────────────────────────────────────────────────────────

    function tokenURI(uint256 playerId)
        public
        view
        override
        playerExists(playerId)
        returns (string memory)
    {
        Player memory p = _players[playerId];
        address club    = ownerOf(playerId);

        string memory json = string(abi.encodePacked(
            '{"name":"', p.name, ' #', playerId.toString(), '",',
            '"description":"Transferium Protocol - Professional Football Player Registration",',
            '"attributes":[',
                '{"trait_type":"Position","value":"', p.position, '"},',
                '{"trait_type":"Nationality","value":"', p.nationality, '"},',
                '{"trait_type":"Verified","value":"', p.isVerified ? "true" : "false", '"},',
                '{"trait_type":"Medical Clearance","value":"', p.medicalClearance ? "true" : "false", '"},',
                '{"trait_type":"Listed","value":"', p.isListed ? "true" : "false", '"},',
                '{"trait_type":"Weekly Salary (EURC)","value":', p.weeklySalary.toString(), '},',
                '{"trait_type":"Current Club","value":"', Strings.toHexString(uint256(uint160(club)), 20), '"},',
                '{"trait_type":"Contract Expiry","value":', p.contractExpiry.toString(), '}',
            ']}'
        ));

        return string(abi.encodePacked(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        ));
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

    function withdrawFees(address payable to, uint256 amount)
        external
        nonReentrant
        onlyRole(ADMIN_ROLE)
    {
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0 || amount > MAX_WITHDRAW) revert WithdrawAmountTooLarge();
        if (amount > address(this).balance) revert InsufficientBalance();
        (bool success, ) = to.call{value: amount}("");
        if (!success) revert WithdrawFailed();
        emit FeesWithdrawn(to, amount);
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

    function getLegalDocuments(uint256 playerId)
        external
        view
        override
        playerExists(playerId)
        returns (LegalDocuments memory)
    {
        return _legalDocs[playerId];
    }

    function getClubPlayers(address club)
        external
        view
        override
        returns (uint256[] memory)
    {
        return _clubPlayers[club];
    }

    function currentClub(uint256 playerId)
        external
        view
        override
        playerExists(playerId)
        returns (address)
    {
        return ownerOf(playerId);
    }

    function hasClubRole(address account) external view override returns (bool) {
        return hasRole(CLUB_ROLE, account);
    }

    function totalPlayers() external view override returns (uint256) {
        return _playerIdCounter;
    }

    // ─── ERC-165 ──────────────────────────────────────────────────────────────
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
