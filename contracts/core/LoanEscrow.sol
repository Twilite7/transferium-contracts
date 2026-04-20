// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IPlayerRegistry.sol";
import "./TransferWindow.sol";

/**
 * @title LoanEscrow
 * @author Transferium Protocol
 * @notice Escrow contract for professional football player loan deals.
 *         Handles loan fee escrow, player ownership transfer to borrowing club,
 *         expiry return, recall clauses, and optional permanent purchase.
 * @dev Security-first: pull payments, strict state machine, reentrancy guards,
 *      whitelisted tokens only. Player ownership always has a defined home.
 *      Requires ESCROW_ROLE on PlayerRegistry — must be granted post-deployment by admin.
 */
contract LoanEscrow is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Roles ────────────────────────────────────────────────────────────────
    bytes32 public constant ADMIN_ROLE  = keccak256("ADMIN_ROLE");
    bytes32 public constant LEAGUE_ROLE = keccak256("LEAGUE_ROLE");
    bytes32 public constant CLUB_ROLE   = keccak256("CLUB_ROLE");

    // ─── Constants ────────────────────────────────────────────────────────────
    uint256 public constant DISPUTE_WINDOW    = 48 hours;
    uint256 public constant MIN_LOAN_DURATION = 30 days;
    uint256 public constant MAX_LOAN_DURATION = 365 days;
    uint256 public constant MIN_RECALL_NOTICE = 14 days;
    uint256 public constant MAX_PRICE         = 500_000_000 ether;
    uint256 public constant MAX_LOAN_FEE      = 100_000_000 ether;

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

    // ─── State ────────────────────────────────────────────────────────────────
    uint256 private _loanIdCounter;

    // I store loan durations separately to avoid struct stack depth issues
    mapping(uint256 => uint256) private _loanDurations;

    IPlayerRegistry public immutable playerRegistry;
    TransferWindow  public immutable transferWindow;

    mapping(uint256 => Loan)                        private _loans;
    mapping(address => mapping(address => uint256)) private _claimable;
    mapping(uint256 => uint256)                     private _activePlayerLoan;
    mapping(address => bool)                        private _approvedTokens;
    address[]                                       private _approvedTokenList;

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

    // ─── Constructor ──────────────────────────────────────────────────────────
    constructor(address _playerRegistry, address _transferWindow) {
        if (_playerRegistry == address(0)) revert InvalidAddress();
        if (_transferWindow == address(0)) revert InvalidAddress();

        playerRegistry = IPlayerRegistry(_playerRegistry);
        transferWindow = TransferWindow(_transferWindow);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(LEAGUE_ROLE, msg.sender);
    }

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
        if (loanFee == 0 || loanFee > MAX_LOAN_FEE) revert InvalidAmount();
        if (loanDuration < MIN_LOAN_DURATION || loanDuration > MAX_LOAN_DURATION) revert InvalidDuration();
        if (hasOptionToBuy && (optionPrice == 0 || optionPrice > MAX_PRICE)) revert InvalidOptionPrice();
        if (!hasOptionToBuy && optionPrice != 0) revert InvalidOptionPrice();
        if (_activePlayerLoan[playerId] != 0) revert LoanAlreadyActive();
        if (!transferWindow.isWindowOpen()) revert TransferWindowClosed();

        // I verify parent club still holds CLUB_ROLE
        if (!playerRegistry.hasClubRole(parentClub)) revert ParentClubNotRegistered();

        // I verify player is listed and belongs to the stated parent club
        IPlayerRegistry.Player memory player = playerRegistry.getPlayer(playerId);
        if (!player.isListed) revert PlayerNotListed();
        if (playerRegistry.currentClub(playerId) != parentClub) revert ParentClubMismatch();

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
        if (loan.state != LoanState.PENDING) revert LoanNotPending();

        // effects
        loan.state = LoanState.CANCELLED;
        _activePlayerLoan[loan.playerId] = 0;
        _claimable[msg.sender][loan.paymentToken] += loan.loanFee;

        emit LoanCancelled(loanId);
    }

    // ─── League Authority Functions ───────────────────────────────────────────

    /**
     * @notice League approves the loan and transfers player to borrowing club.
     * @dev I update all state before the external registry call — CEI pattern.
     *      The registry call is the last action in this function.
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

        // effects — all state settled before external call
        loan.state      = LoanState.ACTIVE;
        loan.loanStart  = block.timestamp;
        loan.loanExpiry = block.timestamp + _loanDurations[loanId];
        loan.approvedAt = block.timestamp;

        // interaction — external call last
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
        if (loan.parentClub != msg.sender) revert NotParentClub();
        if (loan.state != LoanState.ACTIVE) revert LoanNotActive();
        if (block.timestamp < loan.approvedAt + DISPUTE_WINDOW) revert DisputeWindowActive();
        if (loan.loanFeeClaimed) revert LoanFeeAlreadyClaimed();

        loan.loanFeeClaimed = true;
        _claimable[msg.sender][loan.paymentToken] += loan.loanFee;

        emit LoanFeeClaimed(loanId);
    }

    function requestRecall(uint256 loanId)
        external
        whenNotPaused
        nonReentrant
        loanExists(loanId)
    {
        Loan storage loan = _loans[loanId];
        if (loan.parentClub != msg.sender) revert NotParentClub();
        if (loan.state != LoanState.ACTIVE) revert LoanNotActive();
        if (loan.recallRequestedAt != 0) revert RecallAlreadyRequested();

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
        if (loan.parentClub != msg.sender) revert NotParentClub();
        if (loan.state != LoanState.ACTIVE) revert LoanNotActive();
        if (loan.recallRequestedAt == 0) revert LoanNotActive();
        if (block.timestamp < loan.recallRequestedAt + MIN_RECALL_NOTICE) revert RecallNoticeNotMet();

        // effects
        loan.state = LoanState.RECALLED;
        _activePlayerLoan[loan.playerId] = 0;

        // interaction
        playerRegistry.escrowTransfer(loan.playerId, loan.borrowingClub, loan.parentClub);

        emit LoanRecalled(loanId);
    }

    // ─── Expiry Settlement ────────────────────────────────────────────────────

    /**
     * @notice Settles an expired loan and returns player to parent club.
     * @dev I restrict callers to parentClub, borrowingClub, or LEAGUE_ROLE only.
     *      This prevents third-party griefing by triggering expiry at an
     *      inconvenient moment for either club.
     */
    function settleLoanExpiry(uint256 loanId)
        external
        whenNotPaused
        nonReentrant
        loanExists(loanId)
    {
        Loan storage loan = _loans[loanId];
        if (loan.state != LoanState.ACTIVE) revert LoanNotActive();
        if (block.timestamp < loan.loanExpiry) revert LoanStillActive();

        // I restrict who can trigger expiry settlement
        bool authorised = msg.sender == loan.parentClub ||
                          msg.sender == loan.borrowingClub ||
                          hasRole(LEAGUE_ROLE, msg.sender);
        if (!authorised) revert NotAuthorised();

        // effects
        loan.state = LoanState.EXPIRED;
        _activePlayerLoan[loan.playerId] = 0;

        // interaction
        playerRegistry.escrowTransfer(loan.playerId, loan.borrowingClub, loan.parentClub);

        emit LoanExpired(loanId);
    }

    // ─── Option to Buy ────────────────────────────────────────────────────────

    /**
     * @notice Borrowing club exercises the option to buy before loan expiry.
     * @dev Player is already at the borrowing club from approveLoan — no ownership
     *      change is needed here. The loan is marked COMPLETED and the parent club
     *      receives the option price via pull withdrawal.
     *      CEI: state and claimable updated before the safeTransferFrom interaction.
     */
    function exerciseOption(uint256 loanId)
        external
        whenNotPaused
        nonReentrant
        loanExists(loanId)
    {
        Loan storage loan = _loans[loanId];
        if (loan.borrowingClub != msg.sender) revert NotBorrowingClub();
        if (loan.state != LoanState.ACTIVE) revert LoanNotActive();
        if (!loan.hasOptionToBuy) revert NoOptionToBuy();
        if (block.timestamp >= loan.loanExpiry) revert OptionExpired();

        // I check allowance before any state changes for a clear revert message
        uint256 allowance = IERC20(loan.paymentToken).allowance(msg.sender, address(this));
        if (allowance < loan.optionPrice) revert InsufficientAllowance();

        // effects
        loan.state = LoanState.COMPLETED;
        _activePlayerLoan[loan.playerId] = 0;
        _claimable[loan.parentClub][loan.paymentToken] += loan.optionPrice;

        // interaction — pull option price from borrowing club
        IERC20(loan.paymentToken).safeTransferFrom(msg.sender, address(this), loan.optionPrice);

        // Note: player ownership is already at borrowingClub from approveLoan.
        // COMPLETED state means no expiry or recall can move it back — ownership
        // is permanently settled at borrowingClub without a registry call needed here.

        emit OptionExercised(loanId, loan.optionPrice);
    }

    // ─── Pull Withdrawal ──────────────────────────────────────────────────────

    function withdrawClaimable(address token)
        external
        nonReentrant
        onlyApprovedToken(token)
    {
        uint256 amount = _claimable[msg.sender][token];
        if (amount == 0) revert NothingToClaim();

        _claimable[msg.sender][token] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);

        emit FundsClaimed(msg.sender, token, amount);
    }

    // ─── Admin Functions ──────────────────────────────────────────────────────
    function pause() external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

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
