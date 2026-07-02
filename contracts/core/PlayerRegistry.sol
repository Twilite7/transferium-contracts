// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IPlayerRegistry.sol";

interface IPlayerTokenURIRenderer {
    function render(
        IPlayerRegistry.Player memory p,
        IPlayerRegistry.LegalDocuments memory ld
    ) external pure returns (string memory);
}

interface ITerminationManager {
    function clearTermination(uint256 playerId) external;
}

/**
 * @title  PlayerRegistry
 * @author Transferium Protocol
 * @notice ERC-721 registry for professional football players.
 *         Each NFT = one registered player. Ownership = current club.
 *
 * @dev    UUPS upgradeable. Call initialize() on the proxy after deployment.
 *
 *         Verification logic lives in VerificationManager (VERIFICATION_ROLE).
 *         Termination logic lives in TerminationManager (ESCROW_ROLE).
 *         Grant both roles after deploying the satellite contracts.
 */
contract PlayerRegistry is
    IPlayerRegistry,
    Initializable,
    ERC721Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // ─── Roles ────────────────────────────────────────────────────────────────

    bytes32 public constant ADMIN_ROLE        = keccak256("ADMIN_ROLE");
    bytes32 public constant REGISTRAR_ROLE    = keccak256("REGISTRAR_ROLE");
    bytes32 public constant CLUB_ROLE         = keccak256("CLUB_ROLE");
    bytes32 public constant ESCROW_ROLE       = keccak256("ESCROW_ROLE");
    bytes32 public constant LEAGUE_ROLE       = keccak256("LEAGUE_ROLE");
    bytes32 public constant VERIFICATION_ROLE = keccak256("VERIFICATION_ROLE");

    // ─── Constants ────────────────────────────────────────────────────────────

    uint256 public constant MAX_FEE                    = 10_000 * 1e6;
    uint256 public constant MAX_PROTOCOL_FEE_BPS       = 2_000;
    uint256 public constant MAX_REGISTRAR_FEE_EXCESS   = 2_000;
    uint256 public constant WALLET_UPDATE_TIMELOCK     = 48 hours;
    uint256 public constant FEE_SCHEDULE_DELAY         = 10 days;
    uint256 public constant TREASURY_UPDATE_DELAY      = 48 hours;
    uint256 public constant MAX_NAME_LENGTH            = 64;

    // ─── External contracts ───────────────────────────────────────────────────

    IERC20                  public EURC;
    IPlayerTokenURIRenderer public tokenURIRenderer;
    address                 public terminationManager;

    // ─── Protocol fees ────────────────────────────────────────────────────────

    uint64  public registrationFee;
    uint64  public listingFee;
    uint64  public baseVerificationFee;
    uint16  public protocolFeeBps;

    uint64  private _pendingBaseVerificationFee;
    uint256 private _pendingBaseVerificationFeeEffectiveAt;

    // ─── Protocol treasury ────────────────────────────────────────────────────

    address public  protocolTreasury;
    address private _pendingProtocolTreasury;
    uint256 private _pendingProtocolTreasuryEffectiveAt;

    // ─── Fee accumulator ──────────────────────────────────────────────────────

    uint256 public  protocolFeesAccumulated;

    // ─── Custom reentrancy guard ──────────────────────────────────────────────
    // I inline the guard so the lock lives in proxy storage initialised via
    // initialize(), not a constructor — correct for all UUPS upgrade paths.

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;
    uint256 private         _reentrancyStatus;

    // ─── Pause accounting ─────────────────────────────────────────────────────

    uint256 private _pausedAt;
    uint256 public  totalPausedDuration;

    // ─── Player state ─────────────────────────────────────────────────────────

    uint256 public  totalPlayers;

    mapping(uint256 => Player)         private _players;
    mapping(uint256 => LegalDocuments) private _legalDocs;
    mapping(address => uint256[])      private _clubPlayers;
    mapping(bytes32  => bool)          private _usedPlayerHashes;
    mapping(bytes32  => bool)          private _usedDocumentHashes;
    mapping(bytes32  => bool)          private _usedFifaIds;

    // ─── Verification gate ────────────────────────────────────────────────────
    // Full VerificationRequest state lives in VerificationManager.
    // PlayerRegistry only tracks the active gate so document/wallet setters
    // can guard against mid-verification modifications cheaply.

    mapping(uint256 => bool) public  verificationActive;

    // ─── Club state ───────────────────────────────────────────────────────────

    mapping(address => string)  private _clubNames;
    mapping(address => address) private _clubRegistrar;

    // ─── Registrar state ──────────────────────────────────────────────────────

    mapping(address => uint256) private _registrarFee;
    mapping(address => uint256) private _registrarClaimable;

    // ─── Wallet update state ──────────────────────────────────────────────────

    mapping(uint256 => WalletUpdateRequest) private _walletUpdateRequests;

    // ─── Wallet uniqueness ────────────────────────────────────────────────────
    // I track which player a wallet is assigned to so duplicate wallet
    // assignments across different players are rejected at the contract level.
    // 0 means unassigned (valid since player IDs start at 1).
    mapping(address => uint256) private _walletToPlayer;

    // ─── Storage gap ──────────────────────────────────────────────────────────

    uint256[50] private __gap;

    // ─── Errors ───────────────────────────────────────────────────────────────

    error ReentrantCall();
    error ZeroAddress();
    error ZeroAmount();
    error EmptyString();

    error PlayerDoesNotExist(uint256 playerId);
    error PlayerAlreadyRegistered(bytes32 playerHash);
    error FifaIdAlreadyRegistered(bytes32 fifaId);
    error FifaIdRequired();
    error NameTooLong(uint256 length, uint256 max);

    error CallerIsNotPlayerClub(uint256 playerId, address caller);
    error CallerIsNotPlayerWallet(uint256 playerId, address caller);
    error RegistrarNotAssignedToClub(address club);
    error RegistrarNotRegistered(address registrar);
    error RegistrarAlreadyRegistered(address registrar);

    error ClubAlreadyRegistered(address club);
    error ClubNotRegistered(address club);
    error ClubHasActivePlayers(address club, uint256 count);

    error VerificationAlreadyActive(uint256 playerId);

    error HashAlreadyUsed(bytes32 hash);
    error HashesNotDistinct();
    error InvalidHashZero();

    error PlayerNotVerified(uint256 playerId);
    error PlayerAlreadyListed(uint256 playerId);
    error PlayerNotListed(uint256 playerId);

    error FeeTooHigh(uint256 provided, uint256 max);
    error FeeBpsTooHigh(uint256 provided, uint256 max);
    error RegistrarFeeTooHigh(uint256 provided, uint256 maxAllowed);
    error NothingToWithdraw();
    error InsufficientProtocolBalance(uint256 requested, uint256 available);
    error NoPendingFeeSchedule();
    error FeeScheduleNotReady(uint256 effectiveAt, uint256 now_);

    error NoPendingTreasuryUpdate();
    error TreasuryUpdateNotReady(uint256 effectiveAt, uint256 now_);

    error WalletUpdateAlreadyPending(uint256 playerId);
    error NoWalletUpdatePending(uint256 playerId);
    error WalletUpdateNotReady(uint256 playerId, uint256 adjustedExecutable, uint256 now_);
    error WalletUpdateAlreadySet(uint256 playerId, address wallet);
    error WalletAlreadyAssigned(address wallet, uint256 assignedTo);

    error DirectTransferNotAllowed();

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier nonReentrant() {
        if (_reentrancyStatus == _ENTERED) revert ReentrantCall();
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }

    modifier playerExists(uint256 playerId) {
        if (_players[playerId].id == 0) revert PlayerDoesNotExist(playerId);
        _;
    }

    modifier onlyPlayerClub(uint256 playerId) {
        if (ownerOf(playerId) != msg.sender)
            revert CallerIsNotPlayerClub(playerId, msg.sender);
        _;
    }

    modifier onlyPlayerWallet(uint256 playerId) {
        if (_players[playerId].playerWallet != msg.sender)
            revert CallerIsNotPlayerWallet(playerId, msg.sender);
        _;
    }

    // ─── Constructor & initializer ────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address eurc_,
        uint64  registrationFee_,
        uint64  listingFee_,
        uint64  baseVerificationFee_,
        address treasury_
    ) external initializer {
        if (eurc_     == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        if (registrationFee_ > MAX_FEE) revert FeeTooHigh(registrationFee_, MAX_FEE);
        if (listingFee_      > MAX_FEE) revert FeeTooHigh(listingFee_,      MAX_FEE);

        __ERC721_init("Transferium Player", "TRFP");
        __AccessControl_init();
        __Pausable_init();
        _reentrancyStatus = _NOT_ENTERED;

        EURC             = IERC20(eurc_);
        registrationFee      = registrationFee_;
        listingFee           = listingFee_;
        baseVerificationFee  = baseVerificationFee_;
        protocolTreasury = treasury_;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE,         msg.sender);
    }

    function _authorizeUpgrade(address) internal override onlyRole(ADMIN_ROLE) {}

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN — Role management
    // ═══════════════════════════════════════════════════════════════════════════

    function registerClub(address club, string calldata name, address registrar)
        external onlyRole(ADMIN_ROLE)
    {
        if (club      == address(0))              revert ZeroAddress();
        if (registrar == address(0))              revert ZeroAddress();
        if (bytes(name).length == 0)              revert EmptyString();
        if (bytes(name).length > MAX_NAME_LENGTH) revert NameTooLong(bytes(name).length, MAX_NAME_LENGTH);
        if (hasRole(CLUB_ROLE, club))             revert ClubAlreadyRegistered(club);
        if (!hasRole(REGISTRAR_ROLE, registrar))  revert RegistrarNotRegistered(registrar);

        _grantRole(CLUB_ROLE, club);
        _clubNames[club]     = name;
        _clubRegistrar[club] = registrar;
        emit ClubRegistered(club, name, registrar);
    }

    function deregisterClub(address club) external onlyRole(ADMIN_ROLE) {
        if (!hasRole(CLUB_ROLE, club))     revert ClubNotRegistered(club);
        if (_clubPlayers[club].length > 0) revert ClubHasActivePlayers(club, _clubPlayers[club].length);
        _revokeRole(CLUB_ROLE, club);
        delete _clubRegistrar[club];
        delete _clubNames[club];
        emit ClubDeregistered(club);
    }

    function grantRegistrarRole(address registrar) external onlyRole(ADMIN_ROLE) {
        if (registrar == address(0))            revert ZeroAddress();
        if (hasRole(REGISTRAR_ROLE, registrar)) revert RegistrarAlreadyRegistered(registrar);
        _grantRole(REGISTRAR_ROLE, registrar);
        emit RegistrarRoleGranted(registrar);
    }

    function revokeRegistrarRole(address registrar) external onlyRole(ADMIN_ROLE) {
        if (!hasRole(REGISTRAR_ROLE, registrar)) revert RegistrarNotRegistered(registrar);
        _revokeRole(REGISTRAR_ROLE, registrar);
        emit RegistrarRoleRevoked(registrar);
    }

    function grantLeagueRole(address league) external onlyRole(ADMIN_ROLE) {
        if (league == address(0)) revert ZeroAddress();
        _grantRole(LEAGUE_ROLE, league);
    }

    function revokeLeagueRole(address league) external onlyRole(ADMIN_ROLE) {
        _revokeRole(LEAGUE_ROLE, league);
    }

    function grantEscrowRole(address escrow) external onlyRole(ADMIN_ROLE) {
        if (escrow == address(0)) revert ZeroAddress();
        _grantRole(ESCROW_ROLE, escrow);
    }

    function grantVerificationRole(address verifier) external onlyRole(ADMIN_ROLE) {
        if (verifier == address(0)) revert ZeroAddress();
        _grantRole(VERIFICATION_ROLE, verifier);
    }

    // ─── Admin setters ────────────────────────────────────────────────────────

    function setTokenURIRenderer(address renderer) external onlyRole(ADMIN_ROLE) {
        if (renderer == address(0)) revert ZeroAddress();
        tokenURIRenderer = IPlayerTokenURIRenderer(renderer);
    }

    function setTerminationManager(address mgr) external onlyRole(ADMIN_ROLE) {
        if (mgr == address(0)) revert ZeroAddress();
        terminationManager = mgr;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN — Fee configuration
    // ═══════════════════════════════════════════════════════════════════════════

    function setRegistrationFee(uint64 fee) external onlyRole(ADMIN_ROLE) {
        if (fee > MAX_FEE) revert FeeTooHigh(fee, MAX_FEE);
        registrationFee = fee;
        emit RegistrationFeeSet(fee);
    }

    function setListingFee(uint64 fee) external onlyRole(ADMIN_ROLE) {
        if (fee > MAX_FEE) revert FeeTooHigh(fee, MAX_FEE);
        listingFee = fee;
        emit ListingFeeSet(fee);
    }

    function setProtocolFeeBps(uint16 bps) external onlyRole(ADMIN_ROLE) {
        if (bps > MAX_PROTOCOL_FEE_BPS) revert FeeBpsTooHigh(bps, MAX_PROTOCOL_FEE_BPS);
        protocolFeeBps = bps;
        emit ProtocolFeeBpsSet(bps);
    }

    function scheduleBaseVerificationFee(uint64 newFee) external onlyRole(ADMIN_ROLE) {
        if (newFee > MAX_FEE) revert FeeTooHigh(newFee, MAX_FEE);
        _pendingBaseVerificationFee            = newFee;
        _pendingBaseVerificationFeeEffectiveAt = block.timestamp + FEE_SCHEDULE_DELAY;
        emit BaseVerificationFeeScheduled(newFee, _pendingBaseVerificationFeeEffectiveAt);
    }

    function activateBaseVerificationFee() external {
        if (_pendingBaseVerificationFeeEffectiveAt == 0)        revert NoPendingFeeSchedule();
        if (block.timestamp < _pendingBaseVerificationFeeEffectiveAt)
            revert FeeScheduleNotReady(_pendingBaseVerificationFeeEffectiveAt, block.timestamp);
        baseVerificationFee                    = _pendingBaseVerificationFee;
        _pendingBaseVerificationFeeEffectiveAt = 0;
        emit BaseVerificationFeeActivated(baseVerificationFee);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN — Treasury management
    // ═══════════════════════════════════════════════════════════════════════════

    function scheduleProtocolTreasuryUpdate(address newTreasury) external onlyRole(ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        _pendingProtocolTreasury            = newTreasury;
        _pendingProtocolTreasuryEffectiveAt = block.timestamp + TREASURY_UPDATE_DELAY;
        emit ProtocolTreasuryUpdateScheduled(newTreasury, _pendingProtocolTreasuryEffectiveAt);
    }

    function executeProtocolTreasuryUpdate() external onlyRole(ADMIN_ROLE) {
        if (_pendingProtocolTreasuryEffectiveAt == 0)
            revert NoPendingTreasuryUpdate();
        if (block.timestamp < _pendingProtocolTreasuryEffectiveAt)
            revert TreasuryUpdateNotReady(_pendingProtocolTreasuryEffectiveAt, block.timestamp);
        address old      = protocolTreasury;
        protocolTreasury = _pendingProtocolTreasury;
        _pendingProtocolTreasuryEffectiveAt = 0;
        emit ProtocolTreasuryUpdated(old, protocolTreasury);
    }

    function withdrawFees(uint256 amount) external onlyRole(ADMIN_ROLE) nonReentrant {
        if (amount == 0)                       revert ZeroAmount();
        if (amount > protocolFeesAccumulated) revert InsufficientProtocolBalance(amount, protocolFeesAccumulated);
        protocolFeesAccumulated -= amount;
        EURC.safeTransfer(protocolTreasury, amount);
        emit FeesWithdrawn(protocolTreasury, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN — Pause
    // ═══════════════════════════════════════════════════════════════════════════

    function pause() external onlyRole(ADMIN_ROLE) {
        _pausedAt = block.timestamp;
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        if (_pausedAt != 0) {
            totalPausedDuration += block.timestamp - _pausedAt;
            _pausedAt = 0;
        }
        _unpause();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // REGISTRAR — Fee & earnings
    // ═══════════════════════════════════════════════════════════════════════════

    function setVerificationFee(uint256 fee) external onlyRole(REGISTRAR_ROLE) {
        if (fee > MAX_FEE) revert FeeTooHigh(fee, MAX_FEE);
        if (baseVerificationFee > 0) {
            uint256 maxAllowed = baseVerificationFee
                + (uint256(baseVerificationFee) * MAX_REGISTRAR_FEE_EXCESS / 10_000);
            if (fee > maxAllowed) revert RegistrarFeeTooHigh(fee, maxAllowed);
        }
        _registrarFee[msg.sender] = fee;
        emit VerificationFeeSet(msg.sender, fee);
    }

    function withdrawRegistrarFees() external onlyRole(REGISTRAR_ROLE) nonReentrant {
        uint256 amount = _registrarClaimable[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        _registrarClaimable[msg.sender] = 0;
        EURC.safeTransfer(msg.sender, amount);
        emit RegistrarFeesWithdrawn(msg.sender, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CLUB — Player registration
    // ═══════════════════════════════════════════════════════════════════════════

    function registerPlayer(
        string  calldata name,
        string  calldata position,
        string  calldata nationality,
        uint40           contractExpiry,
        uint256          weeklySalary,
        bytes32          fifaId
    ) external onlyRole(CLUB_ROLE) whenNotPaused nonReentrant {
        if (bytes(name).length == 0)              revert EmptyString();
        if (bytes(name).length > MAX_NAME_LENGTH) revert NameTooLong(bytes(name).length, MAX_NAME_LENGTH);
        if (fifaId == bytes32(0))                 revert FifaIdRequired();

        bytes32 playerHash = keccak256(abi.encodePacked(name, msg.sender, fifaId));
        if (_usedPlayerHashes[playerHash]) revert PlayerAlreadyRegistered(playerHash);
        if (_usedFifaIds[fifaId])          revert FifaIdAlreadyRegistered(fifaId);

        if (registrationFee > 0) {
            EURC.safeTransferFrom(msg.sender, address(this), registrationFee);
            protocolFeesAccumulated += registrationFee;
        }

        totalPlayers++;
        uint256 playerId = totalPlayers;

        _players[playerId] = Player({
            id:                  playerId,
            name:                name,
            position:            position,
            nationality:         nationality,
            weeklySalary:        weeklySalary,
            askingPrice:         0,
            releaseClause:       0,
            medicalDocumentHash: bytes32(0),
            fifaId:              fifaId,
            playerWallet:        address(0),
            contractExpiry:      contractExpiry,
            registeredAt:        uint40(block.timestamp),
            isVerified:          false,
            isListed:            false,
            medicalClearance:    false,
            medicalVerified:     false,
            portraitCID:         ""
        });

        _usedPlayerHashes[playerHash] = true;
        _usedFifaIds[fifaId]          = true;
        _clubPlayers[msg.sender].push(playerId);

        _safeMint(msg.sender, playerId);
        emit PlayerRegistered(playerId, name, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CLUB — Document submission
    // ═══════════════════════════════════════════════════════════════════════════

    function setMedicalClearance(uint256 playerId, bytes32 documentHash)
        external onlyRole(CLUB_ROLE) onlyPlayerClub(playerId) whenNotPaused playerExists(playerId)
    {
        if (documentHash == bytes32(0))      revert InvalidHashZero();
        if (verificationActive[playerId])   revert VerificationAlreadyActive(playerId);

        bytes32 oldHash = _players[playerId].medicalDocumentHash;
        if (documentHash != oldHash) {
            if (_usedDocumentHashes[documentHash]) revert HashAlreadyUsed(documentHash);
            if (oldHash != bytes32(0)) _usedDocumentHashes[oldHash] = false;
            _usedDocumentHashes[documentHash] = true;
        }

        _players[playerId].medicalDocumentHash = documentHash;
        _players[playerId].medicalClearance    = true;
        _players[playerId].medicalVerified     = false;
        emit MedicalClearanceSet(playerId, documentHash);
    }

    function submitLegalDocuments(
        uint256 playerId,
        bytes32 registrationContractHash,
        bytes32 fifaTMSHash,
        bytes32 workPermitHash
    ) external onlyRole(CLUB_ROLE) onlyPlayerClub(playerId) whenNotPaused playerExists(playerId) {
        if (registrationContractHash == bytes32(0)) revert InvalidHashZero();
        if (fifaTMSHash              == bytes32(0)) revert InvalidHashZero();
        if (registrationContractHash == fifaTMSHash) revert HashesNotDistinct();
        if (workPermitHash != bytes32(0) && workPermitHash == registrationContractHash) revert HashesNotDistinct();
        if (workPermitHash != bytes32(0) && workPermitHash == fifaTMSHash)              revert HashesNotDistinct();
        if (verificationActive[playerId]) revert VerificationAlreadyActive(playerId);

        LegalDocuments storage existing = _legalDocs[playerId];
        _releaseDocHash(existing.registrationContractHash, registrationContractHash);
        _releaseDocHash(existing.fifaTMSHash,              fifaTMSHash);
        _releaseDocHash(existing.workPermitHash,           workPermitHash);

        if (_usedDocumentHashes[registrationContractHash]) revert HashAlreadyUsed(registrationContractHash);
        if (_usedDocumentHashes[fifaTMSHash])              revert HashAlreadyUsed(fifaTMSHash);
        if (workPermitHash != bytes32(0) && _usedDocumentHashes[workPermitHash]) revert HashAlreadyUsed(workPermitHash);

        _usedDocumentHashes[registrationContractHash] = true;
        _usedDocumentHashes[fifaTMSHash]              = true;
        if (workPermitHash != bytes32(0)) _usedDocumentHashes[workPermitHash] = true;

        _legalDocs[playerId] = LegalDocuments({
            registrationContractHash: registrationContractHash,
            fifaTMSHash:              fifaTMSHash,
            workPermitHash:           workPermitHash,
            documentsVerified:        false
        });

        emit LegalDocumentsSubmitted(playerId);
    }

    function setPlayerWallet(uint256 playerId, address wallet)
        external onlyRole(CLUB_ROLE) onlyPlayerClub(playerId) whenNotPaused playerExists(playerId)
    {
        if (wallet == address(0))                      revert ZeroAddress();
        if (_players[playerId].playerWallet == wallet) revert WalletUpdateAlreadySet(playerId, wallet);
        if (verificationActive[playerId])              revert VerificationAlreadyActive(playerId);
        // I reject wallets already assigned to a different player
        uint256 currentOwner = _walletToPlayer[wallet];
        if (currentOwner != 0 && currentOwner != playerId)
            revert WalletAlreadyAssigned(wallet, currentOwner);
        // I clear the reverse mapping for the old wallet if one existed
        address oldWallet = _players[playerId].playerWallet;
        if (oldWallet != address(0)) delete _walletToPlayer[oldWallet];
        _walletToPlayer[wallet] = playerId;
        _players[playerId].playerWallet = wallet;
        emit PlayerWalletSet(playerId, wallet);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CLUB — Listing
    // ═══════════════════════════════════════════════════════════════════════════

    function listPlayer(uint256 playerId, uint256 askingPrice)
        external onlyRole(CLUB_ROLE) onlyPlayerClub(playerId) whenNotPaused playerExists(playerId)
    {
        Player storage p = _players[playerId];
        if (!p.isVerified) revert PlayerNotVerified(playerId);
        if (p.isListed)    revert PlayerAlreadyListed(playerId);

        if (listingFee > 0) {
            EURC.safeTransferFrom(msg.sender, address(this), listingFee);
            protocolFeesAccumulated += listingFee;
        }

        p.isListed    = true;
        p.askingPrice = askingPrice;
        emit PlayerListed(playerId, askingPrice);
    }

    function delistPlayer(uint256 playerId)
        external onlyRole(CLUB_ROLE) onlyPlayerClub(playerId) whenNotPaused playerExists(playerId)
    {
        if (!_players[playerId].isListed) revert PlayerNotListed(playerId);
        _players[playerId].isListed    = false;
        _players[playerId].askingPrice = 0;
        emit PlayerDelisted(playerId);
    }

    function updateAskingPrice(uint256 playerId, uint256 askingPrice)
        external onlyRole(CLUB_ROLE) onlyPlayerClub(playerId) whenNotPaused playerExists(playerId)
    {
        if (!_players[playerId].isListed) revert PlayerNotListed(playerId);
        _players[playerId].askingPrice = askingPrice;
    }

    function setReleaseClause(uint256 playerId, uint256 amount)
        external onlyRole(CLUB_ROLE) onlyPlayerClub(playerId) whenNotPaused playerExists(playerId)
    {
        _players[playerId].releaseClause = amount;
        emit ReleaseClauseSet(playerId, amount);
    }

    function extendContract(uint256 playerId, uint40 newExpiry)
        external onlyRole(CLUB_ROLE) onlyPlayerClub(playerId) whenNotPaused playerExists(playerId)
    {
        _players[playerId].contractExpiry = uint40(newExpiry);
        emit ContractExtended(playerId, newExpiry);
    }


    // ═══════════════════════════════════════════════════════════════════════════
    // CLUB — Wallet update (cancel)
    // ═══════════════════════════════════════════════════════════════════════════

    function cancelWalletUpdate(uint256 playerId)
        external onlyRole(CLUB_ROLE) onlyPlayerClub(playerId) playerExists(playerId)
    {
        if (!_walletUpdateRequests[playerId].active) revert NoWalletUpdatePending(playerId);
        delete _walletUpdateRequests[playerId];
        emit WalletUpdateCancelled(playerId);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PLAYER WALLET — Wallet rotation
    // ═══════════════════════════════════════════════════════════════════════════

    function initiateWalletUpdate(uint256 playerId, address newWallet)
        external onlyPlayerWallet(playerId) whenNotPaused playerExists(playerId)
    {
        if (newWallet == address(0))                      revert ZeroAddress();
        if (newWallet == _players[playerId].playerWallet) revert WalletUpdateAlreadySet(playerId, newWallet);
        if (_walletUpdateRequests[playerId].active)       revert WalletUpdateAlreadyPending(playerId);
        // I reject wallets already assigned to a different player
        uint256 currentOwner = _walletToPlayer[newWallet];
        if (currentOwner != 0 && currentOwner != playerId)
            revert WalletAlreadyAssigned(newWallet, currentOwner);

        _walletUpdateRequests[playerId] = WalletUpdateRequest({
            newWallet:     newWallet,
            executable:    block.timestamp + WALLET_UPDATE_TIMELOCK,
            pauseSnapshot: totalPausedDuration,
            active:        true
        });

        emit WalletUpdateInitiated(playerId, newWallet, block.timestamp + WALLET_UPDATE_TIMELOCK);
    }

    function executeWalletUpdate(uint256 playerId) external playerExists(playerId) {
        WalletUpdateRequest storage req = _walletUpdateRequests[playerId];
        if (!req.active) revert NoWalletUpdatePending(playerId);

        uint256 pausedSince        = totalPausedDuration - req.pauseSnapshot;
        uint256 adjustedExecutable = req.executable + pausedSince;

        if (block.timestamp < adjustedExecutable)
            revert WalletUpdateNotReady(playerId, adjustedExecutable, block.timestamp);

        address oldWallet = _players[playerId].playerWallet;
        address newWallet = req.newWallet;
        delete _walletUpdateRequests[playerId];
        // I update the reverse mapping atomically with the wallet change
        if (oldWallet != address(0)) delete _walletToPlayer[oldWallet];
        _walletToPlayer[newWallet] = playerId;
        _players[playerId].playerWallet = newWallet;

        emit WalletUpdateExecuted(playerId, oldWallet, newWallet);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ESCROW
    // ═══════════════════════════════════════════════════════════════════════════

    function escrowTransfer(uint256 playerId, address fromClub, address toClub)
        external onlyRole(ESCROW_ROLE) playerExists(playerId)
    {
        if (fromClub == address(0)) revert ZeroAddress();
        if (toClub   == address(0)) revert ZeroAddress();

        if (terminationManager != address(0))
            ITerminationManager(terminationManager).clearTermination(playerId);

        verificationActive[playerId] = false;

        Player storage p = _players[playerId];
        p.isListed         = false;
        p.askingPrice      = 0;
        p.releaseClause    = 0;
        p.medicalClearance = false;
        p.medicalVerified  = false;

        if (p.medicalDocumentHash != bytes32(0)) {
            _usedDocumentHashes[p.medicalDocumentHash] = false;
            p.medicalDocumentHash = bytes32(0);
        }

        LegalDocuments storage ld = _legalDocs[playerId];
        if (ld.registrationContractHash != bytes32(0)) _usedDocumentHashes[ld.registrationContractHash] = false;
        if (ld.fifaTMSHash              != bytes32(0)) _usedDocumentHashes[ld.fifaTMSHash]              = false;
        if (ld.workPermitHash           != bytes32(0)) _usedDocumentHashes[ld.workPermitHash]           = false;
        delete _legalDocs[playerId];

        _removeFromClub(playerId, fromClub);
        _clubPlayers[toClub].push(playerId);

        _transfer(fromClub, toClub, playerId);
        emit ClubOwnershipTransferred(playerId, fromClub, toClub);
    }

    function burnPlayer(uint256 playerId)
        external onlyRole(ESCROW_ROLE) playerExists(playerId)
    {
        _burnPlayer(playerId);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VERIFICATION CALLBACKS — called by VerificationManager only
    // ═══════════════════════════════════════════════════════════════════════════

    function setVerificationActive(uint256 playerId, bool active)
        external onlyRole(VERIFICATION_ROLE)
    {
        verificationActive[playerId] = active;
    }

    function setMedicalVerified(uint256 playerId, address actor)
        external onlyRole(VERIFICATION_ROLE) playerExists(playerId)
    {
        _players[playerId].medicalVerified = true;
        emit MedicalClearanceVerified(playerId, actor);
    }

    function setLegalDocsVerified(uint256 playerId, address actor)
        external onlyRole(VERIFICATION_ROLE) playerExists(playerId)
    {
        _legalDocs[playerId].documentsVerified = true;
        emit LegalDocumentsVerified(playerId, actor);
    }

    function markPlayerVerified(uint256 playerId, address actor)
        external onlyRole(VERIFICATION_ROLE) playerExists(playerId)
    {
        _players[playerId].isVerified = true;
        emit VerificationApproved(playerId, actor);
        emit PlayerVerified(playerId, actor);
    }

    function addProtocolFees(uint256 amount) external onlyRole(VERIFICATION_ROLE) {
        protocolFeesAccumulated += amount;
    }

    function addRegistrarFees(address registrar, uint256 amount) external onlyRole(VERIFICATION_ROLE) {
        _registrarClaimable[registrar] += amount;
    }

    function resetWallet(uint256 playerId, address actor)
        external onlyRole(VERIFICATION_ROLE) playerExists(playerId)
    {
        address _oldWallet = _players[playerId].playerWallet;
        if (_oldWallet != address(0)) delete _walletToPlayer[_oldWallet];
        _players[playerId].playerWallet = address(0);
        if (_walletUpdateRequests[playerId].active) {
            delete _walletUpdateRequests[playerId];
            emit WalletUpdateCancelled(playerId);
        }
        emit PlayerWalletReset(playerId, actor);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function getPlayer(uint256 playerId)
        external view playerExists(playerId) returns (Player memory)
    {
        return _players[playerId];
    }

    function getLegalDocuments(uint256 playerId)
        external view playerExists(playerId) returns (LegalDocuments memory)
    {
        return _legalDocs[playerId];
    }

    function getClubPlayers(address club) external view returns (uint256[] memory) {
        return _clubPlayers[club];
    }

    function getClubRegistrar(address club) external view returns (address) {
        return _clubRegistrar[club];
    }

    function getClubName(address club) external view returns (string memory) {
        return _clubNames[club];
    }


    function getRegistrarFee(address registrar) external view returns (uint256) {
        return _registrarFee[registrar];
    }

    function getRegistrarClaimable(address registrar) external view returns (uint256) {
        return _registrarClaimable[registrar];
    }
    /// @notice Returns the player ID assigned to a wallet address, or 0 if unassigned.
    function getPlayerByWallet(address wallet) external view returns (uint256) {
        return _walletToPlayer[wallet];
    }




    function currentClub(uint256 playerId) external view returns (address) {
        return ownerOf(playerId);
    }

    function hasClubRole(address account) external view returns (bool) {
        return hasRole(CLUB_ROLE, account);
    }






    // ═══════════════════════════════════════════════════════════════════════════
    // ERC-721 OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    function transferFrom(address, address, uint256) public pure override {
        revert DirectTransferNotAllowed();
    }

    function safeTransferFrom(address, address, uint256, bytes memory) public pure override {
        revert DirectTransferNotAllowed();
    }

    function approve(address, uint256) public pure override {
        revert DirectTransferNotAllowed();
    }

    function setApprovalForAll(address, bool) public pure override {
        revert DirectTransferNotAllowed();
    }

    function tokenURI(uint256 playerId)
        public view override playerExists(playerId) returns (string memory)
    {
        return tokenURIRenderer.render(_players[playerId], _legalDocs[playerId]);
    }

    function supportsInterface(bytes4 interfaceId)
        public view override(ERC721Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    function _burnPlayer(uint256 playerId) internal {
        address club = ownerOf(playerId);

        verificationActive[playerId] = false;

        if (terminationManager != address(0))
            ITerminationManager(terminationManager).clearTermination(playerId);

        delete _walletUpdateRequests[playerId];

        LegalDocuments storage ld = _legalDocs[playerId];
        if (ld.registrationContractHash != bytes32(0)) _usedDocumentHashes[ld.registrationContractHash] = false;
        if (ld.fifaTMSHash              != bytes32(0)) _usedDocumentHashes[ld.fifaTMSHash]              = false;
        if (ld.workPermitHash           != bytes32(0)) _usedDocumentHashes[ld.workPermitHash]           = false;

        bytes32 medHash = _players[playerId].medicalDocumentHash;
        if (medHash != bytes32(0)) _usedDocumentHashes[medHash] = false;

        bytes32 fifaId = _players[playerId].fifaId;
        if (fifaId != bytes32(0)) _usedFifaIds[fifaId] = false;

        delete _legalDocs[playerId];
        delete _players[playerId];

        _removeFromClub(playerId, club);
        _burn(playerId);

        emit PlayerBurned(playerId);
    }

    function _removeFromClub(uint256 playerId, address club) internal {
        uint256[] storage ids = _clubPlayers[club];
        uint256 len = ids.length;
        for (uint256 i = 0; i < len; i++) {
            if (ids[i] == playerId) {
                ids[i] = ids[len - 1];
                ids.pop();
                return;
            }
        }
    }

    function _releaseDocHash(bytes32 existing, bytes32 incoming) internal {
        if (existing != bytes32(0) && existing != incoming) {
            _usedDocumentHashes[existing] = false;
        }
    }
}
