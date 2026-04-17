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
 * @title TransferEscrow
 * @author Transferium Protocol
 * @notice Escrow contract for professional football player transfers.
 *         Buying club deposits funds, league authority confirms, selling club withdraws.
 * @dev Security-first: pull payments, state machine, reentrancy guards, whitelisted tokens only.
 *      On deal completion, calls PlayerRegistry to update on-chain club ownership.
 */
contract TransferEscrow is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Roles ────────────────────────────────────────────────────────────────
    bytes32 public constant ADMIN_ROLE  = keccak256("ADMIN_ROLE");
    bytes32 public constant LEAGUE_ROLE = keccak256("LEAGUE_ROLE");
    bytes32 public constant CLUB_ROLE   = keccak256("CLUB_ROLE");

    // ─── Constants ────────────────────────────────────────────────────────────
    uint256 public constant DISPUTE_WINDOW  = 48 hours;
    uint256 public constant MAX_SELL_ON_BPS = 2000;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_PRICE       = 500_000_000 ether;

    // ─── Deal State Machine ───────────────────────────────────────────────────
    enum DealState {
        NONE,
        PENDING,
        APPROVED,
        COMPLETED,
        REJECTED,
        CANCELLED
    }

    struct Deal {
        uint256 playerId;
        address buyingClub;
        address sellingClub;
        address paymentToken;
        uint256 transferFee;
        uint256 sellOnBps;
        address sellOnRecipient;
        DealState state;
        uint256 createdAt;
        uint256 approvedAt;
        string  rejectionReason;
    }

    uint256 private _dealIdCounter;

    // I store the PlayerRegistry address — set once at construction, immutable
    IPlayerRegistry public immutable playerRegistry;
    TransferWindow public immutable transferWindow;

    mapping(uint256 => Deal) private _deals;
    mapping(address => mapping(address => uint256)) private _claimable;
    mapping(uint256 => uint256) private _activePlayerDeal;
    mapping(address => bool) private _approvedTokens;
    address[] private _approvedTokenList;

    // ─── Events ───────────────────────────────────────────────────────────────
    event DealCreated(uint256 indexed dealId, uint256 indexed playerId, address buyingClub, address sellingClub, uint256 transferFee);
    event DealApproved(uint256 indexed dealId, address indexed approver);
    event DealRejected(uint256 indexed dealId, address indexed approver, string reason);
    event DealCompleted(uint256 indexed dealId, address indexed newClub);
    event DealCancelled(uint256 indexed dealId);
    event FundsClaimed(address indexed recipient, address indexed token, uint256 amount);
    event TokenApproved(address indexed token);
    event TokenRevoked(address indexed token);

    // ─── Errors ───────────────────────────────────────────────────────────────
    error InvalidAddress();
    error InvalidAmount();
    error InvalidBps();
    error TokenNotApproved();
    error TokenAlreadyApproved();
    error TokenNotInList();
    error DealNotFound();
    error DealNotPending();
    error DealNotApproved();
    error DealAlreadyActive();
    error DisputeWindowActive();
    error NotBuyingClub();
    error NotSellingClub();
    error NothingToClaim();
    error InvalidString();
    error TransferWindowClosed();

    // ─── Constructor ──────────────────────────────────────────────────────────
    constructor(address _playerRegistry, address _transferWindow) {
        if (_playerRegistry == address(0)) revert InvalidAddress();

        playerRegistry = IPlayerRegistry(_playerRegistry);
        if (_transferWindow == address(0)) revert InvalidAddress();
        transferWindow = TransferWindow(_transferWindow);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(LEAGUE_ROLE, msg.sender);
    }

    // ─── Modifiers ────────────────────────────────────────────────────────────
    modifier dealExists(uint256 dealId) {
        if (_deals[dealId].createdAt == 0) revert DealNotFound();
        _;
    }

    modifier onlyApprovedToken(address token) {
        if (!_approvedTokens[token]) revert TokenNotApproved();
        _;
    }

    // ─── Token Whitelist Management ───────────────────────────────────────────

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

    // ─── Buying Club Functions ────────────────────────────────────────────────

    function createDeal(
        uint256 playerId,
        address sellingClub,
        address paymentToken,
        uint256 transferFee,
        uint256 sellOnBps,
        address sellOnRecipient
    )
        external
        whenNotPaused
        nonReentrant
        onlyRole(CLUB_ROLE)
        onlyApprovedToken(paymentToken)
        returns (uint256 dealId)
    {
        if (sellingClub == address(0) || sellingClub == msg.sender) revert InvalidAddress();
        if (transferFee == 0 || transferFee > MAX_PRICE) revert InvalidAmount();
        if (sellOnBps > MAX_SELL_ON_BPS) revert InvalidBps();
        if (sellOnBps > 0 && sellOnRecipient == address(0)) revert InvalidAddress();
        if (_activePlayerDeal[playerId] != 0) revert DealAlreadyActive();
        if (!transferWindow.isWindowOpen()) revert TransferWindowClosed();

        // I verify the player exists and is listed before creating the deal
        IPlayerRegistry.Player memory player = playerRegistry.getPlayer(playerId);
        require(player.isListed, "Player not listed for transfer");
        require(player.currentClub == sellingClub, "Selling club mismatch");

        _dealIdCounter++;
        dealId = _dealIdCounter;

        _deals[dealId] = Deal({
            playerId:        playerId,
            buyingClub:      msg.sender,
            sellingClub:     sellingClub,
            paymentToken:    paymentToken,
            transferFee:     transferFee,
            sellOnBps:       sellOnBps,
            sellOnRecipient: sellOnRecipient,
            state:           DealState.PENDING,
            createdAt:       block.timestamp,
            approvedAt:      0,
            rejectionReason: ""
        });

        _activePlayerDeal[playerId] = dealId;

        IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), transferFee);

        emit DealCreated(dealId, playerId, msg.sender, sellingClub, transferFee);
    }

    function cancelDeal(uint256 dealId)
        external
        whenNotPaused
        nonReentrant
        dealExists(dealId)
    {
        Deal storage deal = _deals[dealId];
        if (deal.buyingClub != msg.sender) revert NotBuyingClub();
        if (deal.state != DealState.PENDING) revert DealNotPending();

        deal.state = DealState.CANCELLED;
        _activePlayerDeal[deal.playerId] = 0;

        _claimable[msg.sender][deal.paymentToken] += deal.transferFee;

        emit DealCancelled(dealId);
    }

    // ─── League Authority Functions ───────────────────────────────────────────

    function approveDeal(uint256 dealId)
        external
        whenNotPaused
        nonReentrant
        onlyRole(LEAGUE_ROLE)
        dealExists(dealId)
    {
        Deal storage deal = _deals[dealId];
        if (deal.state != DealState.PENDING) revert DealNotPending();

        deal.state      = DealState.APPROVED;
        deal.approvedAt = block.timestamp;

        emit DealApproved(dealId, msg.sender);
    }

    function rejectDeal(uint256 dealId, string calldata reason)
        external
        whenNotPaused
        nonReentrant
        onlyRole(LEAGUE_ROLE)
        dealExists(dealId)
    {
        if (bytes(reason).length == 0 || bytes(reason).length > 256) revert InvalidString();

        Deal storage deal = _deals[dealId];
        if (deal.state != DealState.PENDING) revert DealNotPending();

        deal.state           = DealState.REJECTED;
        deal.rejectionReason = reason;
        _activePlayerDeal[deal.playerId] = 0;

        _claimable[deal.buyingClub][deal.paymentToken] += deal.transferFee;

        emit DealRejected(dealId, msg.sender, reason);
    }

    // ─── Selling Club Functions ───────────────────────────────────────────────

    /**
     * @notice Selling club claims funds after dispute window.
     * @dev On success, calls PlayerRegistry to update on-chain club ownership.
     *      I update state before external call to prevent reentrancy.
     */
    function claimFunds(uint256 dealId)
        external
        whenNotPaused
        nonReentrant
        dealExists(dealId)
    {
        Deal storage deal = _deals[dealId];
        if (deal.sellingClub != msg.sender) revert NotSellingClub();
        if (deal.state != DealState.APPROVED) revert DealNotApproved();
        if (block.timestamp < deal.approvedAt + DISPUTE_WINDOW) revert DisputeWindowActive();

        // I update state before any external calls — checks-effects-interactions
        deal.state = DealState.COMPLETED;
        _activePlayerDeal[deal.playerId] = 0;

        uint256 sellOnAmount = 0;
        uint256 sellerAmount = deal.transferFee;

        if (deal.sellOnBps > 0 && deal.sellOnRecipient != address(0)) {
            sellOnAmount = (deal.transferFee * deal.sellOnBps) / BPS_DENOMINATOR;
            sellerAmount = deal.transferFee - sellOnAmount;
            _claimable[deal.sellOnRecipient][deal.paymentToken] += sellOnAmount;
        }

        _claimable[msg.sender][deal.paymentToken] += sellerAmount;

        // I call PlayerRegistry last — state is already settled before this external call
        playerRegistry.transferClubOwnership(deal.playerId, deal.buyingClub);

        emit DealCompleted(dealId, deal.buyingClub);
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
    function getDeal(uint256 dealId) external view dealExists(dealId) returns (Deal memory) {
        return _deals[dealId];
    }

    function getClaimable(address account, address token) external view returns (uint256) {
        return _claimable[account][token];
    }

    function getActivePlayerDeal(uint256 playerId) external view returns (uint256) {
        return _activePlayerDeal[playerId];
    }

    function isTokenApproved(address token) external view returns (bool) {
        return _approvedTokens[token];
    }

    function getApprovedTokens() external view returns (address[] memory) {
        return _approvedTokenList;
    }

    function totalDeals() external view returns (uint256) {
        return _dealIdCounter;
    }
}
