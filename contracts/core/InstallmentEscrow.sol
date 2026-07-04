// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../base/ProtocolFeeBase.sol";

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../types/TransferTypes.sol";
import "../interfaces/IDealEscrow.sol";

/**
 * @title InstallmentEscrow
 * @notice Handles post-completion installment payments for transfer deals.
 *         Makes zero changes to DealEscrow — uses only existing view functions.
 *         Tracks paid state in its own _paid mapping.
 * @dev index 0 is always paid via fundDeal. This contract handles index >= 1.
 *      An installment exists if getInstallment(dealId, index).amount > 0.
 *      InvalidIndex fires if index == 0 or the installment amount is zero.
 */
contract InstallmentEscrow is
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

    // COMPLETED is ordinal 13 in DealState enum (AWAITING_THIRD_PARTY_MEDICAL removed)
    uint8 constant DEAL_COMPLETED = 13;

    // ─── State ────────────────────────────────────────────────────────────────
    IDealEscrow public dealEscrow;
    mapping(address => mapping(address => uint256)) private _claimable;
    // _paid[dealId][index] — own paid tracking, does not write back to DealEscrow
    mapping(uint256 => mapping(uint8 => bool)) private _paid;

    // 40-slot storage gap for future upgrades
    uint256[40] private __gap;

    // ─── Events ───────────────────────────────────────────────────────────────
    event InstallmentPaid(uint256 indexed dealId, uint8 indexed index, uint256 amount);
    event InstallmentOverdue(uint256 indexed dealId, uint8 indexed index, uint256 dueDate);
    event Claimed(address indexed recipient, address indexed token, uint256 amount);

    // ─── Errors ───────────────────────────────────────────────────────────────
    error NotBuyingClub();
    error InstallmentNotDue();
    error InstallmentAlreadyPaid();
    error InstallmentNotOverdue();
    error InvalidIndex();
    error WrongDealState();
    error NothingToClaim();
    error InvalidAddress();
    error NothingToWithdraw();
    error ReentrantCall();
    error InsufficientProtocolBalance(uint256 requested, uint256 available);

    // ─── Constructor ──────────────────────────────────────────────────────────
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    // ─── Initializer ──────────────────────────────────────────────────────────
    function initialize(
        address _dealEscrow,
        address _treasury,
        address _admin
    ) external initializer {
        if (_dealEscrow == address(0)) revert InvalidAddress();
        if (_treasury   == address(0)) revert InvalidAddress();
        if (_admin      == address(0)) revert InvalidAddress();

        __AccessControl_init();
        __Pausable_init();
        _reentrancyStatus = _NOT_ENTERED;

        dealEscrow     = IDealEscrow(_dealEscrow);
        treasury       = _treasury;
        protocolFeeBps = 50;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE,         _admin);
        _grantRole(LEAGUE_ROLE,        _admin);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ─── Core ─────────────────────────────────────────────────────────────────

    /**
     * @notice Buying club pays a deferred installment for a completed deal.
     * @dev Uses getDealView (existing) for parties + state.
     *      Uses getInstallment (existing) for amount + dueDate.
     *      index 0 is reserved for fundDeal upfront payment — always InvalidIndex here.
     *      If getInstallment returns amount == 0 the index is out of range — InvalidIndex.
     */
    function payInstallment(uint256 dealId, uint8 index)
        external
        whenNotPaused
        nonReentrant
    {
        if (index == 0) revert InvalidIndex();

        IDealEscrow.DealView memory deal = dealEscrow.getDealView(dealId);
        if (deal.buyingClub != msg.sender)       revert NotBuyingClub();
        if (uint8(deal.state) != DEAL_COMPLETED) revert WrongDealState();

        TransferTypes.Installment memory inst = dealEscrow.getInstallment(dealId, index);
        if (inst.amount == 0)                    revert InvalidIndex();
        if (_paid[dealId][index])                revert InstallmentAlreadyPaid();
        if (block.timestamp < inst.dueDate)      revert InstallmentNotDue();

        // CEI: mark paid before pulling funds
        _paid[dealId][index] = true;

        IERC20(deal.paymentToken).safeTransferFrom(msg.sender, address(this), inst.amount);

        uint256 protocolAmt = (protocolFeeBps > 0 && treasury != address(0))
            ? inst.amount * protocolFeeBps / 10_000 : 0;
        uint256 sellerAmt   = inst.amount - protocolAmt;

        if (protocolAmt > 0) _claimable[treasury][deal.paymentToken]      += protocolAmt;
        _claimable[deal.sellingClub][deal.paymentToken] += sellerAmt;

        emit InstallmentPaid(dealId, index, inst.amount);
    }

    /**
     * @notice League flags an overdue installment for record-keeping / sanctions.
     */
    function flagOverdue(uint256 dealId, uint8 index)
        external
        onlyRole(LEAGUE_ROLE)
    {
        if (index == 0) revert InvalidIndex();

        IDealEscrow.DealView memory deal = dealEscrow.getDealView(dealId);
        if (uint8(deal.state) != DEAL_COMPLETED) revert WrongDealState();

        TransferTypes.Installment memory inst = dealEscrow.getInstallment(dealId, index);
        if (inst.amount == 0)                    revert InvalidIndex();
        if (_paid[dealId][index])                revert InstallmentAlreadyPaid();
        if (block.timestamp <= inst.dueDate)     revert InstallmentNotOverdue();

        emit InstallmentOverdue(dealId, index, inst.dueDate);
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    function isPaid(uint256 dealId, uint8 index) external view returns (bool) {
        return _paid[dealId][index];
    }

    function claimable(address account, address token) external view returns (uint256) {
        return _claimable[account][token];
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

    function withdrawFees(address token, uint256 amount)
        external
        onlyRole(ADMIN_ROLE)
        nonReentrant
    {
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

    // ─── Pull Withdrawal ──────────────────────────────────────────────────────

    /**
     * @notice Withdraw claimable balance. Not gated on whenNotPaused —
     *         users must always be able to withdraw their own funds.
     */
    function claim(address token) external nonReentrant {
        uint256 amt = _claimable[msg.sender][token];
        if (amt == 0) revert NothingToClaim();
        _claimable[msg.sender][token] = 0;
        IERC20(token).safeTransfer(msg.sender, amt);
        emit Claimed(msg.sender, token, amt);
    }
}
