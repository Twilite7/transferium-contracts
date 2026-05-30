// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../base/ProtocolFeeBase.sol";

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IPlayerRegistry.sol";
import "../interfaces/ITransferWindow.sol";
import "../interfaces/IAddressRegistry.sol";
import "../utils/RegistryKeys.sol";

/**
 * @title LoanEscrow
 * @author Transferium Protocol
 * @notice Escrow contract for professional football player loan deals.
 *         Handles loan fee escrow, player ownership transfer to borrowing club,
 *         expiry return, recall clauses, and optional permanent purchase.
 * @dev UUPS upgradeable. Security-first: pull payments, strict state machine,
 *      custom reentrancy guard, whitelisted tokens only. Critical address
 *      updates (playerRegistry, addressRegistry) are timelocked at 48 hours.
 *      Storage gap of 40 slots reserved for future upgrades.
 *      Requires ESCROW_ROLE on PlayerRegistry — must be granted post-deployment.
 */
contract LoanEscrow is
    ProtocolFeeBase,
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // ─── Reentrancy Guard ─────────────────────────────────────────────────────
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;
    uint256 private _reentrancyStatus;

    modifier nonReentrant() {
        if (_reentrancyStatus == _ENTERED) revert ReentrantCall();
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }

    // ─── Roles ────────────────────────────────────────────────────────────────
    bytes32 public constant ADMIN_ROLE  = keccak256("ADMIN_ROLE");
    bytes32 public constant LEAGUE_ROLE = keccak256("LEAGUE_ROLE");
    bytes32 public constant CLUB_ROLE   = keccak256("CLUB_ROLE");

    // ─── Constants ────────────────────────────────────────────────────────────
    uint256 public constant DISPUTE_WINDOW       = 48 hours;
    uint256 public constant MIN_LOAN_DURATION    = 30 days;
    uint256 public constant MAX_LOAN_DURATION    = 365 days;
    uint256 public constant MIN_RECALL_NOTICE    = 14 days;
    uint256 public constant MAX_PRICE            = 500_000_000 ether;
    uint256 public constant MAX_LOAN_FEE         = 100_000_000 ether;
    // I timelock critical address changes to match treasury timelock in ProtocolFeeBase
    uint256 public constant REGISTRY_UPDATE_DELAY = 48 hours;

    // ─── Loan State Machine ───────────────────────────────────────────────────
    enum LoanState {
        NONE,
        PENDING,    // borrowing club deposited fee, awaiting league approval
        ACTIVE,     // league approved, player is at borrowing club
        COMPLETED,  // option to buy exercised — player permanently at borrowing club
        EXPIRED,    // loan ended, player returned to parent club
        RECALLED,   // parent club recalled player early
        REJECTED,   // league rejected the loan
        CANCELLED   // cancelled before approval
    }

    struct Loan {
        uint256   playerId;
        address   parentClub;
        address   borrowingClub;
        address   paymentToken;
        uint256   loanFee;
        uint256   loanStart;
        uint256   loanExpiry;
        bool      hasOptionToBuy;
        uint256   optionPrice;
        LoanState state;
        uint256   createdAt;
        uint256   approvedAt;
        uint256   recallRequestedAt;
        bool      loanFeeClaimed;    // I use a flag instead of zeroing loanFee to keep history readable
        string    rejectionReason;
    }

    // I use a shared struct for both timelocked registry updates
    struct PendingRegistryUpdate {
        address newAddress;
        uint256 scheduledAt;
        bool    exists;
    }

    // ─── State Variables ──────────────────────────────────────────────────────
    uint256 private _loanIdCounter;

    // I store loan durations separately to avoid struct stack depth issues
    mapping(uint256 => uint256) private _loanDurations;

    IPlayerRegistry  public playerRegistry;
    IAddressRegistry public addressRegistry;

    // I timelock registry address changes — compromise of ADMIN_ROLE alone
    // is insufficient to immediately redirect player/registry calls
    PendingRegistryUpdate private _pendingPlayerRegistry;
    PendingRegistryUpdate private _pendingAddressRegistry;

    mapping(uint256 => Loan)                        private _loans;
    mapping(address => mapping(address => uint256)) private _claimable;
    mapping(uint256 => uint256)                     private _activePlayerLoan;
    mapping(address => bool)                        private _approvedTokens;
    address[]                                       private _approvedTokenList;

    // I reserve 40 storage slots for future upgrades — never remove or reorder
    // variables above this line
    uint256[40] private __gap;

    // ─── Events ───────────────────────────────────────────────────────────────
    event LoanCreated(uint256 indexed loanId, uint256 indexed playerId, address parentClub, address borrowingClub, uint256 loanFee);
    event LoanApproved(uint256 indexed loanId, address indexed approver);
    event LoanRejected(uint256 indexed loanId, address indexed approver, string reason);
    event LoanFeeClaimed(uint256 indexed loanId);
    event LoanExpired(uint256 indexed loanId);
    event RecallRequested(uint256 indexed loanId, uint256 recallExecutableAt);
    event LoanRecalled(uint256 indexed loanId);
    event OptionExercised(uint256 indexed loanId, uint256 optionPrice);
    event LoanCancelled(uint256 indexed loanId);
    event FundsClaimed(address indexed recipient, address indexed token, uint256 amount);
    event TokenApproved(address indexed token);
    event TokenRevoked(address indexed token);
    event PlayerRegistryUpdateScheduled(address indexed newAddress, uint256 executableAt);
    event PlayerRegistryUpdated(address indexed oldAddress, address indexed newAddress);
    event AddressRegistryUpdateScheduled(address indexed newAddress, uint256 executableAt);
    event AddressRegistryUpdated(address indexed oldAddress, address indexed newAddress);

    // ─── Errors ───────────────────────────────────────────────────────────────
    error InvalidAddress();
    error InvalidAmount();
    error InvalidDuration();
    error InvalidOptionPrice();
    error TokenNotApproved();
    error TokenAlreadyApproved();
    error TokenNotInList();
    error LoanNotFound();
    error LoanNotPending();
    error LoanNotActive();
    error LoanAlreadyActive();
    error DisputeWindowActive();
    error LoanStillActive();
    error NotParentClub();
    error NotBorrowingClub();
    error NotAuthorised();
    error NothingToClaim();
    error LoanFeeAlreadyClaimed();
    error InvalidString();
    error TransferWindowClosed();
    error RecallNoticeNotMet();
    error RecallAlreadyRequested();
    error NoOptionToBuy();
    error OptionExpired();
    error InsufficientAllowance();
    error PlayerNotListed();
    error ParentClubMismatch();
    error ParentClubNotRegistered();
    error NothingToWithdraw();
    error InsufficientProtocolBalance(uint256 requested, uint256 available);
    error ReentrantCall();
    error NoPendingRegistryUpdate();
    error RegistryUpdateNotReady();

    // ─── Constructor ──────────────────────────────────────────────────────────
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    // ─── Initializer ──────────────────────────────────────────────────────────
    function initialize(
        address _playerRegistry,
        address _addressRegistry,
        address _treasury,
        address _admin
    ) external initializer {
        if (_playerRegistry  == address(0)) revert InvalidAddress();
        if (_addressRegistry == address(0)) revert InvalidAddress();
        if (_treasury        == address(0)) revert InvalidAddress();
        if (_admin           == address(0)) revert InvalidAddress();

        __AccessControl_init();
        __Pausable_init();
        _reentrancyStatus = _NOT_ENTERED;

        playerRegistry  = IPlayerRegistry(_playerRegistry);
        addressRegistry = IAddressRegistry(_addressRegistry);
        treasury        = _treasury;
        protocolFeeBps  = 50;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE,         _admin);
        _grantRole(LEAGUE_ROLE,        _admin);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ─── Modifiers ────────────────────────────────────────────────────────────
    modifier loanExists(uint256 loanId) {
        if (_loans[loanId].createdAt == 0) revert LoanNotFound();
        _;
    }

    modifier onlyApprovedToken(address token) {
        if (!_approvedTokens[token]) revert TokenNotApproved();
        _;
    }

    // ─── Token Whitelist ──────────────────────────────────────────────────────

    function approveToken(address token) external onlyRole(ADMIN_ROLE) {
        if (token == address(0)) revert InvalidAddress();
        if (_approvedTokens[token]) revert TokenAlreadyApproved();
        _approvedTokens[token] = true;
        _approvedTokenList.push(token);
        emit TokenApproved(token);
    }

    function revokeToken(address token) external onlyRole(ADMIN_ROLE) {
        if (!_approvedTokens[token]) revert TokenNotInList();
        _approvedTokens[token] = false;
        uint256 len = _approvedTokenList.length;
        for (uint256 i = 0; i < len; i++) {
            if (_approvedTokenList[i] == token) {
                _approvedTokenList[i] = _approvedTokenList[len - 1];
                _approvedTokenList.pop();
                break;
            }
        }
        emit TokenRevoked(token);
    }

    // ─── Timelocked Registry Updates ─────────────────────────────────────────

    /**
     * @notice Schedule a playerRegistry address update.
     * @dev 48-hour timelock prevents an ADMIN_ROLE compromise from immediately
     *      redirecting all player lookups to a malicious registry.
     */
    function schedulePlayerRegistryUpdate(address newAddress) external onlyRole(ADMIN_ROLE) {
        if (newAddress == address(0)) revert InvalidAddress();
        _pendingPlayerRegistry = PendingRegistryUpdate({
            newAddress:  newAddress,
            scheduledAt: block.timestamp,
            exists:      true
        });
        emit PlayerRegistryUpdateScheduled(newAddress, block.timestamp + REGISTRY_UPDATE_DELAY);
    }

    function executePlayerRegistryUpdate() external onlyRole(ADMIN_ROLE) {
        if (!_pendingPlayerRegistry.exists) revert NoPendingRegistryUpdate();
        if (block.timestamp < _pendingPlayerRegistry.scheduledAt + REGISTRY_UPDATE_DELAY)
            revert RegistryUpdateNotReady();
        address old    = address(playerRegistry);
        address newAddr = _pendingPlayerRegistry.newAddress;
        delete _pendingPlayerRegistry;
        playerRegistry = IPlayerRegistry(newAddr);
        emit PlayerRegistryUpdated(old, newAddr);
    }

    /**
     * @notice Schedule an addressRegistry update.
     * @dev Same 48-hour timelock — addressRegistry resolves the transfer window,
     *      so redirecting it could bypass all window checks.
     */
    function scheduleAddressRegistryUpdate(address newAddress) external onlyRole(ADMIN_ROLE) {
        if (newAddress == address(0)) revert InvalidAddress();
        _pendingAddressRegistry = PendingRegistryUpdate({
            newAddress:  newAddress,
            scheduledAt: block.timestamp,
            exists:      true
        });
        emit AddressRegistryUpdateScheduled(newAddress, block.timestamp + REGISTRY_UPDATE_DELAY);
    }

    function executeAddressRegistryUpdate() external onlyRole(ADMIN_ROLE) {
        if (!_pendingAddressRegistry.exists) revert NoPendingRegistryUpdate();
        if (block.timestamp < _pendingAddressRegistry.scheduledAt + REGISTRY_UPDATE_DELAY)
            revert RegistryUpdateNotReady();
        address old     = address(addressRegistry);
        address newAddr = _pendingAddressRegistry.newAddress;
        delete _pendingAddressRegistry;
        addressRegistry = IAddressRegistry(newAddr);
        emit AddressRegistryUpdated(old, newAddr);
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function setProtocolFee(uint256 bps) external onlyRole(ADMIN_ROLE) {
        _setProtocolFee(bps);
    }

    function scheduleProtocolTreasuryUpdate(address newTreasury) external onlyRole(ADMIN_ROLE) {
        if (newTreasury == address(0)) revert InvalidAddress();
        _scheduleProtocolTreasuryUpdate(newTreasury);
    }

    function executeProtocolTreasuryUpdate() external onlyRole(ADMIN_ROLE) {
        _executeProtocolTreasuryUpdate();
    }

    function withdrawFees(address token, uint256 amount) external onlyRole(ADMIN_ROLE) nonReentrant {
        if (amount == 0) revert NothingToWithdraw();
        if (treasury == address(0)) revert InvalidAddress();
        uint256 avail = _claimable[treasury][token];
        if (amount > avail) revert InsufficientProtocolBalance(amount, avail);
        _claimable[treasury][token] = avail - amount;
        IERC20(token).safeTransfer(treasury, amount);
        emit ProtocolFeesWithdrawn(treasury, token, amount);
    }

    function pause()   external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    // ─── Borrowing Club Functions ─────────────────────────────────────────────

    /**
     * @notice Borrowing club initiates a loan deal by depositing the loan fee.
     * @dev Transfer window must be open. Player must be listed.
     *      I verify parent club still holds CLUB_ROLE to prevent deals against
     *      deregistered clubs.
     */
    function createLoan(
        uint256 playerId,
        address parentClub,
        address paymentToken,
        uint256 loanFee,
        uint256 loanDuration,
        bool    hasOptionToBuy,
        uint256 optionPrice
    )
        external
        whenNotPaused
        nonReentrant
        onlyRole(CLUB_ROLE)
        onlyApprovedToken(paymentToken)
        returns (uint256 loanId)
    {
        if (parentClub == address(0) || parentClub == msg.sender) revert InvalidAddress();
        if (loanFee == 0 || loanFee > MAX_LOAN_FEE)              revert InvalidAmount();
        if (loanDuration < MIN_LOAN_DURATION || loanDuration > MAX_LOAN_DURATION) revert InvalidDuration();
        if (hasOptionToBuy && (optionPrice == 0 || optionPrice > MAX_PRICE)) revert InvalidOptionPrice();
        if (!hasOptionToBuy && optionPrice != 0)                  revert InvalidOptionPrice();
        if (_activePlayerLoan[playerId] != 0)                     revert LoanAlreadyActive();
        if (!ITransferWindow(addressRegistry.get(RegistryKeys.TRANSFER_WINDOW)).isWindowOpen())
            revert TransferWindowClosed();

        if (!playerRegistry.hasClubRole(parentClub)) revert ParentClubNotRegistered();

        IPlayerRegistry.Player memory player = playerRegistry.getPlayer(playerId);
        if (!player.isListed)                                     revert PlayerNotListed();
        if (playerRegistry.currentClub(playerId) != parentClub)   revert ParentClubMismatch();

        _loanIdCounter++;
        loanId = _loanIdCounter;
        _loanDurations[loanId] = loanDuration;

        _loans[loanId] = Loan({
            playerId:          playerId,
            parentClub:        parentClub,
            borrowingClub:     msg.sender,
            paymentToken:      paymentToken,
            loanFee:           loanFee,
            loanStart:         0,
            loanExpiry:        0,
            hasOptionToBuy:    hasOptionToBuy,
            optionPrice:       optionPrice,
            state:             LoanState.PENDING,
            createdAt:         block.timestamp,
            approvedAt:        0,
            recallRequestedAt: 0,
            loanFeeClaimed:    false,
            rejectionReason:   ""
        });

        _activePlayerLoan[playerId] = loanId;

        // I transfer funds last — CEI order
        IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), loanFee);

        emit LoanCreated(loanId, playerId, parentClub, msg.sender, loanFee);
    }

    function cancelLoan(uint256 loanId)
        external
        whenNotPaused
        nonReentrant
        loanExists(loanId)
    {
        Loan storage loan = _loans[loanId];
        if (loan.borrowingClub != msg.sender) revert NotBorrowingClub();
        if (loan.state != LoanState.PENDING)  revert LoanNotPending();

        loan.state = LoanState.CANCELLED;
        _activePlayerLoan[loan.playerId] = 0;
        _claimable[msg.sender][loan.paymentToken] += loan.loanFee;

        emit LoanCancelled(loanId);
    }

    // ─── League Authority Functions ───────────────────────────────────────────

    /**
     * @notice League approves the loan and transfers player to borrowing club.
     * @dev CEI: all state settled before external registry call.
     */
    function approveLoan(uint256 loanId)
        external
        whenNotPaused
        nonReentrant
        onlyRole(LEAGUE_ROLE)
        loanExists(loanId)
    {
        Loan storage loan = _loans[loanId];
        if (loan.state != LoanState.PENDING) revert LoanNotPending();

        loan.state      = LoanState.ACTIVE;
        loan.loanStart  = block.timestamp;
        loan.loanExpiry = block.timestamp + _loanDurations[loanId];
        loan.approvedAt = block.timestamp;

        playerRegistry.escrowTransfer(loan.playerId, loan.parentClub, loan.borrowingClub);

        emit LoanApproved(loanId, msg.sender);
    }

    function rejectLoan(uint256 loanId, string calldata reason)
        external
        whenNotPaused
        nonReentrant
        onlyRole(LEAGUE_ROLE)
        loanExists(loanId)
    {
        if (bytes(reason).length == 0 || bytes(reason).length > 256) revert InvalidString();

        Loan storage loan = _loans[loanId];
        if (loan.state != LoanState.PENDING) revert LoanNotPending();

        loan.state           = LoanState.REJECTED;
        loan.rejectionReason = reason;
        _activePlayerLoan[loan.playerId] = 0;
        _claimable[loan.borrowingClub][loan.paymentToken] += loan.loanFee;

        emit LoanRejected(loanId, msg.sender, reason);
    }

    // ─── Parent Club Functions ────────────────────────────────────────────────

    /**
     * @notice Parent club claims the loan fee after the 48-hour dispute window.
     * @dev I use a boolean flag rather than zeroing loanFee so loan history
     *      remains readable via getLoan().
     */
    function claimLoanFee(uint256 loanId)
        external
        whenNotPaused
        nonReentrant
        loanExists(loanId)
    {
        Loan storage loan = _loans[loanId];
        if (loan.parentClub != msg.sender)                          revert NotParentClub();
        if (loan.state != LoanState.ACTIVE)                         revert LoanNotActive();
        if (block.timestamp < loan.approvedAt + DISPUTE_WINDOW)     revert DisputeWindowActive();
        if (loan.loanFeeClaimed)                                     revert LoanFeeAlreadyClaimed();

        loan.loanFeeClaimed = true;
        uint256 loanFeeNet  = loan.loanFee;
        if (treasury != address(0) && protocolFeeBps > 0) {
            uint256 protocolAmt = loanFeeNet * protocolFeeBps / 10_000;
            loanFeeNet -= protocolAmt;
            _claimable[treasury][loan.paymentToken] += protocolAmt;
        }
        _claimable[msg.sender][loan.paymentToken] += loanFeeNet;

        emit LoanFeeClaimed(loanId);
    }

    function requestRecall(uint256 loanId)
        external
        whenNotPaused
        nonReentrant
        loanExists(loanId)
    {
        Loan storage loan = _loans[loanId];
        if (loan.parentClub != msg.sender)    revert NotParentClub();
        if (loan.state != LoanState.ACTIVE)   revert LoanNotActive();
        if (loan.recallRequestedAt != 0)      revert RecallAlreadyRequested();

        loan.recallRequestedAt = block.timestamp;

        emit RecallRequested(loanId, block.timestamp + MIN_RECALL_NOTICE);
    }

    /**
     * @notice Parent club executes recall after the notice period has elapsed.
     * @dev CEI: state updated before external registry call.
     */
    function executeRecall(uint256 loanId)
        external
        whenNotPaused
        nonReentrant
        loanExists(loanId)
    {
        Loan storage loan = _loans[loanId];
        if (loan.parentClub != msg.sender)   revert NotParentClub();
        if (loan.state != LoanState.ACTIVE)  revert LoanNotActive();
        if (loan.recallRequestedAt == 0)     revert LoanNotActive();
        if (block.timestamp < loan.recallRequestedAt + MIN_RECALL_NOTICE) revert RecallNoticeNotMet();

        loan.state = LoanState.RECALLED;
        _activePlayerLoan[loan.playerId] = 0;

        playerRegistry.escrowTransfer(loan.playerId, loan.borrowingClub, loan.parentClub);

        emit LoanRecalled(loanId);
    }

    // ─── Expiry Settlement ────────────────────────────────────────────────────

    /**
     * @notice Settles an expired loan and returns player to parent club.
     * @dev I restrict callers to parentClub, borrowingClub, or LEAGUE_ROLE only
     *      to prevent third-party griefing.
     */
    function settleLoanExpiry(uint256 loanId)
        external
        whenNotPaused
        nonReentrant
        loanExists(loanId)
    {
        Loan storage loan = _loans[loanId];
        if (loan.state != LoanState.ACTIVE)         revert LoanNotActive();
        if (block.timestamp < loan.loanExpiry)       revert LoanStillActive();

        bool authorised = msg.sender == loan.parentClub    ||
                          msg.sender == loan.borrowingClub ||
                          hasRole(LEAGUE_ROLE, msg.sender);
        if (!authorised) revert NotAuthorised();

        loan.state = LoanState.EXPIRED;
        _activePlayerLoan[loan.playerId] = 0;

        playerRegistry.escrowTransfer(loan.playerId, loan.borrowingClub, loan.parentClub);

        emit LoanExpired(loanId);
    }

    // ─── Option to Buy ────────────────────────────────────────────────────────

    /**
     * @notice Borrowing club exercises the option to buy before loan expiry.
     * @dev Player is already at the borrowing club from approveLoan — no NFT move needed.
     *      CEI: state and claimable updated before safeTransferFrom to ensure
     *      a transfer revert does not leave a claimable balance backed by no tokens.
     *      Protocol fee deducted only after funds are confirmed received.
     */
    function exerciseOption(uint256 loanId)
        external
        whenNotPaused
        nonReentrant
        loanExists(loanId)
    {
        Loan storage loan = _loans[loanId];
        if (loan.borrowingClub != msg.sender) revert NotBorrowingClub();
        if (loan.state != LoanState.ACTIVE)   revert LoanNotActive();
        if (!loan.hasOptionToBuy)             revert NoOptionToBuy();
        if (block.timestamp >= loan.loanExpiry) revert OptionExpired();

        // I mark COMPLETED and clear active loan before pulling funds
        loan.state = LoanState.COMPLETED;
        _activePlayerLoan[loan.playerId] = 0;

        // I pull funds before crediting claimable — a revert here rolls back
        // the state change above, leaving no phantom claimable balance
        IERC20(loan.paymentToken).safeTransferFrom(msg.sender, address(this), loan.optionPrice);

        uint256 optionNet = loan.optionPrice;
        if (treasury != address(0) && protocolFeeBps > 0) {
            uint256 protocolAmt = optionNet * protocolFeeBps / 10_000;
            optionNet -= protocolAmt;
            _claimable[treasury][loan.paymentToken] += protocolAmt;
        }
        _claimable[loan.parentClub][loan.paymentToken] += optionNet;

        emit OptionExercised(loanId, loan.optionPrice);
    }

    // ─── Pull Withdrawal ──────────────────────────────────────────────────────

    /**
     * @notice Withdraw claimable balance for a token.
     * @dev Deliberately not gated on whenNotPaused — users must always be able
     *      to withdraw their own funds regardless of contract pause state.
     */
    function withdrawClaimable(address token)
        external
        nonReentrant
    {
        uint256 amount = _claimable[msg.sender][token];
        if (amount == 0) revert NothingToClaim();
        _claimable[msg.sender][token] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit FundsClaimed(msg.sender, token, amount);
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    function getLoan(uint256 loanId) external view loanExists(loanId) returns (Loan memory) {
        return _loans[loanId];
    }

    function getClaimable(address account, address token) external view returns (uint256) {
        return _claimable[account][token];
    }

    function getActivePlayerLoan(uint256 playerId) external view returns (uint256) {
        return _activePlayerLoan[playerId];
    }

    function getLoanDuration(uint256 loanId) external view returns (uint256) {
        return _loanDurations[loanId];
    }

    function isTokenApproved(address token) external view returns (bool) {
        return _approvedTokens[token];
    }

    function getApprovedTokens() external view returns (address[] memory) {
        return _approvedTokenList;
    }

    function totalLoans() external view returns (uint256) {
        return _loanIdCounter;
    }
}
