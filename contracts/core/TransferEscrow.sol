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
 * @notice Escrow for permanent professional football transfers.
 * @dev Supports: agent fees, sell-on clauses, performance add-ons (paid to player wallet),
 *      salary guarantee deposit, and admin-triggered add-on payments.
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
    uint256 public constant MAX_AGENT_BPS   = 1000;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_PRICE       = 500_000_000 ether;
    uint256 public constant MAX_ADDONS      = 10;

    // ─── Deal State Machine ───────────────────────────────────────────────────
    enum DealState { NONE, PENDING, APPROVED, COMPLETED, REJECTED, CANCELLED }

    // ─── Structs ──────────────────────────────────────────────────────────────
    struct AddOn {
        string  description;
        uint256 amount;
        bool    toPlayer;    // I route to playerWallet if true, selling club if false
        bool    triggered;
    }

    struct Deal {
        uint256   playerId;
        address   buyingClub;
        address   sellingClub;
        address   paymentToken;
        uint256   transferFee;
        uint256   salaryGuaranteeMonths;  // months of salary deposited as guarantee
        uint256   salaryGuaranteeAmount;  // actual EURC amount locked
        bool      salaryGuaranteeClaimed; // I prevent double claims
        uint256   sellOnBps;
        address   sellOnRecipient;
        uint256   sellerAgentBps;
        address   sellerAgent;
        uint256   buyerAgentBps;
        address   buyerAgent;
        DealState state;
        uint256   createdAt;
        uint256   approvedAt;
        string    rejectionReason;
    }

    uint256 private _dealIdCounter;

    IPlayerRegistry public immutable playerRegistry;
    TransferWindow  public immutable transferWindow;

    mapping(uint256 => Deal)                        private _deals;
    mapping(uint256 => AddOn[])                     private _dealAddOns;
    mapping(address => mapping(address => uint256)) private _claimable;
    mapping(uint256 => uint256)                     private _activePlayerDeal;
    mapping(address => bool)                        private _approvedTokens;
    address[]                                       private _approvedTokenList;

    // ─── Events ───────────────────────────────────────────────────────────────
    event DealCreated(uint256 indexed dealId, uint256 indexed playerId, address buyingClub, address sellingClub, uint256 transferFee);
    event DealApproved(uint256 indexed dealId, address indexed approver);
    event DealRejected(uint256 indexed dealId, address indexed approver, string reason);
    event DealCompleted(uint256 indexed dealId, address indexed newClub);
    event DealCancelled(uint256 indexed dealId);
    event AddOnTriggered(uint256 indexed dealId, uint256 indexed addOnIndex, uint256 amount, address recipient);
    event SalaryGuaranteeClaimed(uint256 indexed dealId, address indexed playerWallet, uint256 amount);
    event FundsClaimed(address indexed recipient, address indexed token, uint256 amount);
    event TokenApproved(address indexed token);
    event TokenRevoked(address indexed token);

    // ─── Errors ───────────────────────────────────────────────────────────────
    error InvalidAddress();
    error InvalidAmount();
    error InvalidBps();
    error TotalFeesExceedTransfer();
    error TokenNotApproved();
    error TokenAlreadyApproved();
    error TokenNotInList();
    error DealNotFound();
    error DealNotPending();
    error DealNotApproved();
    error DealNotCompleted();
    error DealAlreadyActive();
    error DisputeWindowActive();
    error NotBuyingClub();
    error NotSellingClub();
    error NothingToClaim();
    error InvalidString();
    error TransferWindowClosed();
    error PlayerNotListed();
    error SellingClubMismatch();
    error SellingClubNotRegistered();
    error TooManyAddOns();
    error AddOnAlreadyTriggered();
    error AddOnNotFound();
    error PlayerWalletNotSet();
    error SalaryGuaranteeAlreadyClaimed();
    error NoSalaryGuarantee();

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
    modifier dealExists(uint256 dealId) {
        if (_deals[dealId].createdAt == 0) revert DealNotFound();
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

    // ─── Buying Club Functions ────────────────────────────────────────────────

    /**
     * @notice Create a permanent transfer deal.
     * @dev salaryGuaranteeMonths: number of months of salary locked as guarantee.
     *      Set to 0 for no guarantee. The actual amount is computed from
     *      weeklySalary * 4 * salaryGuaranteeMonths and pulled from buying club.
     */
    function createDeal(
        uint256   playerId,
        address   sellingClub,
        address   paymentToken,
        uint256   transferFee,
        uint256   salaryGuaranteeMonths,
        uint256   sellOnBps,
        address   sellOnRecipient,
        uint256   sellerAgentBps,
        address   sellerAgent,
        uint256   buyerAgentBps,
        address   buyerAgent,
        AddOn[]   calldata addOns
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
        if (sellerAgentBps > MAX_AGENT_BPS) revert InvalidBps();
        if (sellerAgentBps > 0 && sellerAgent == address(0)) revert InvalidAddress();
        if (buyerAgentBps > MAX_AGENT_BPS) revert InvalidBps();
        if (buyerAgentBps > 0 && buyerAgent == address(0)) revert InvalidAddress();
        if (addOns.length > MAX_ADDONS) revert TooManyAddOns();
        if ((sellOnBps + sellerAgentBps + buyerAgentBps) > 5000) revert TotalFeesExceedTransfer();
        if (_activePlayerDeal[playerId] != 0) revert DealAlreadyActive();
        if (!transferWindow.isWindowOpen()) revert TransferWindowClosed();
        if (!playerRegistry.hasClubRole(sellingClub)) revert SellingClubNotRegistered();

        IPlayerRegistry.Player memory player = playerRegistry.getPlayer(playerId);
        if (!player.isListed) revert PlayerNotListed();
        if (playerRegistry.currentClub(playerId) != sellingClub) revert SellingClubMismatch();

        // I compute salary guarantee amount from weekly salary
        uint256 salaryGuaranteeAmount = 0;
        if (salaryGuaranteeMonths > 0) {
            salaryGuaranteeAmount = player.weeklySalary * 4 * salaryGuaranteeMonths;
        }

        _dealIdCounter++;
        dealId = _dealIdCounter;

        _deals[dealId] = Deal({
            playerId:                playerId,
            buyingClub:              msg.sender,
            sellingClub:             sellingClub,
            paymentToken:            paymentToken,
            transferFee:             transferFee,
            salaryGuaranteeMonths:   salaryGuaranteeMonths,
            salaryGuaranteeAmount:   salaryGuaranteeAmount,
            salaryGuaranteeClaimed:  false,
            sellOnBps:               sellOnBps,
            sellOnRecipient:         sellOnRecipient,
            sellerAgentBps:          sellerAgentBps,
            sellerAgent:             sellerAgent,
            buyerAgentBps:           buyerAgentBps,
            buyerAgent:              buyerAgent,
            state:                   DealState.PENDING,
            createdAt:               block.timestamp,
            approvedAt:              0,
            rejectionReason:         ""
        });

        for (uint256 i = 0; i < addOns.length; i++) {
            _dealAddOns[dealId].push(AddOn({
                description: addOns[i].description,
                amount:      addOns[i].amount,
                toPlayer:    addOns[i].toPlayer,
                triggered:   false
            }));
        }

        _activePlayerDeal[playerId] = dealId;

        // I pull transfer fee + salary guarantee from buying club
        uint256 totalPull = transferFee + salaryGuaranteeAmount;
        IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), totalPull);

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

        // I refund both transfer fee and salary guarantee
        _claimable[msg.sender][deal.paymentToken] += deal.transferFee + deal.salaryGuaranteeAmount;

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

        // I refund both transfer fee and salary guarantee on rejection
        _claimable[deal.buyingClub][deal.paymentToken] += deal.transferFee + deal.salaryGuaranteeAmount;

        emit DealRejected(dealId, msg.sender, reason);
    }

    /**
     * @notice Trigger a performance add-on payment after off-chain verification.
     * @dev If toPlayer is true, payment goes to playerWallet. Otherwise to selling club.
     *      Performance bonuses (goals, assists, etc.) always set toPlayer = true.
     */
    function triggerAddOn(uint256 dealId, uint256 addOnIndex)
        external
        whenNotPaused
        nonReentrant
        onlyRole(LEAGUE_ROLE)
        dealExists(dealId)
    {
        Deal storage deal = _deals[dealId];
        if (deal.state != DealState.COMPLETED) revert DealNotCompleted();

        AddOn[] storage addOns = _dealAddOns[dealId];
        if (addOnIndex >= addOns.length) revert AddOnNotFound();

        AddOn storage addOn = addOns[addOnIndex];
        if (addOn.triggered) revert AddOnAlreadyTriggered();

        addOn.triggered = true;

        address recipient;
        if (addOn.toPlayer) {
            // I route to player's own wallet
            IPlayerRegistry.Player memory player = playerRegistry.getPlayer(deal.playerId);
            if (player.playerWallet == address(0)) revert PlayerWalletNotSet();
            recipient = player.playerWallet;
        } else {
            recipient = deal.sellingClub;
        }

        // I pull add-on payment from buying club
        IERC20(deal.paymentToken).safeTransferFrom(deal.buyingClub, address(this), addOn.amount);
        _claimable[recipient][deal.paymentToken] += addOn.amount;

        emit AddOnTriggered(dealId, addOnIndex, addOn.amount, recipient);
    }

    // ─── Selling Club Functions ───────────────────────────────────────────────

    /**
     * @notice Selling club claims transfer funds after dispute window.
     * @dev Salary guarantee stays locked — it belongs to the player, not the selling club.
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

        deal.state = DealState.COMPLETED;
        _activePlayerDeal[deal.playerId] = 0;

        uint256 remaining = deal.transferFee;

        if (deal.sellOnBps > 0 && deal.sellOnRecipient != address(0)) {
            uint256 amt = (deal.transferFee * deal.sellOnBps) / BPS_DENOMINATOR;
            remaining  -= amt;
            _claimable[deal.sellOnRecipient][deal.paymentToken] += amt;
        }

        if (deal.sellerAgentBps > 0 && deal.sellerAgent != address(0)) {
            uint256 amt = (deal.transferFee * deal.sellerAgentBps) / BPS_DENOMINATOR;
            remaining  -= amt;
            _claimable[deal.sellerAgent][deal.paymentToken] += amt;
        }

        if (deal.buyerAgentBps > 0 && deal.buyerAgent != address(0)) {
            uint256 amt = (deal.transferFee * deal.buyerAgentBps) / BPS_DENOMINATOR;
            remaining  -= amt;
            _claimable[deal.buyerAgent][deal.paymentToken] += amt;
        }

        _claimable[msg.sender][deal.paymentToken] += remaining;

        // I transfer the player NFT last — CEI pattern
        playerRegistry.escrowTransfer(deal.playerId, deal.sellingClub, deal.buyingClub);

        emit DealCompleted(dealId, deal.buyingClub);
    }

    // ─── Player Functions ─────────────────────────────────────────────────────

    /**
     * @notice Player claims their salary guarantee if the buying club defaults.
     * @dev Only callable by the player's registered playerWallet.
     *      I leave the decision of "when to claim" to the player —
     *      they can claim anytime after the deal completes.
     */
    function claimSalaryGuarantee(uint256 dealId)
        external
        nonReentrant
        dealExists(dealId)
    {
        Deal storage deal = _deals[dealId];
        if (deal.state != DealState.COMPLETED) revert DealNotCompleted();
        if (deal.salaryGuaranteeAmount == 0) revert NoSalaryGuarantee();
        if (deal.salaryGuaranteeClaimed) revert SalaryGuaranteeAlreadyClaimed();

        IPlayerRegistry.Player memory player = playerRegistry.getPlayer(deal.playerId);
        if (player.playerWallet == address(0)) revert PlayerWalletNotSet();
        if (player.playerWallet != msg.sender) revert InvalidAddress();

        deal.salaryGuaranteeClaimed = true;
        _claimable[msg.sender][deal.paymentToken] += deal.salaryGuaranteeAmount;

        emit SalaryGuaranteeClaimed(dealId, msg.sender, deal.salaryGuaranteeAmount);
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

    function getDealAddOns(uint256 dealId) external view dealExists(dealId) returns (AddOn[] memory) {
        return _dealAddOns[dealId];
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
