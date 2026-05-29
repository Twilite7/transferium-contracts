// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../base/ProtocolFeeBase.sol";

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../types/TransferTypes.sol";
import "../interfaces/IDealEscrow.sol";

/**
 * @title InstallmentEscrow
 * @notice Handles post-completion installment payments for transfer deals.
 *         Separated from DealEscrow to keep DealEscrow under the 24KB limit.
 */
contract InstallmentEscrow is ProtocolFeeBase, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant LEAGUE_ROLE = keccak256("LEAGUE_ROLE");

    IDealEscrow public dealEscrow;

    // COMPLETED is ordinal 16 in DealState enum
    uint8 constant DEAL_COMPLETED = 16;

    mapping(address => mapping(address => uint256)) private _claimable;

    event InstallmentPaid(uint256 indexed dealId, uint8 indexed index, uint256 amount);
    event InstallmentOverdue(uint256 indexed dealId, uint8 indexed index, uint256 dueDate);
    event Claimed(address indexed recipient, address indexed token, uint256 amount);

    error NotBuyingClub();
    error InstallmentNotDue();
    error InstallmentAlreadyPaid();
    error InstallmentNotOverdue();
    error InvalidIndex();
    error WrongDealState();
    error NothingToClaim();

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    error InvalidAddress();
    error NothingToWithdraw();
    error InsufficientProtocolBalance(uint256 requested, uint256 available);

    constructor(address _dealEscrow, address _treasury, uint256 _protocolFeeBps) {
        dealEscrow     = IDealEscrow(_dealEscrow);
        treasury       = _treasury;
        protocolFeeBps = _protocolFeeBps;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(LEAGUE_ROLE, msg.sender);
    }

    function payInstallment(uint256 dealId, uint8 index) external whenNotPaused nonReentrant {
        (
            address buyingClub,
            address sellingClub,
            address paymentToken,
            uint8   installmentCount,
            ,
            uint8   state
        ) = dealEscrow.getInstallmentMeta(dealId);

        if (buyingClub != msg.sender)              revert NotBuyingClub();
        if (state != DEAL_COMPLETED)               revert WrongDealState();
        if (index == 0 || index >= installmentCount) revert InvalidIndex();

        TransferTypes.Installment memory inst = dealEscrow.getInstallment(dealId, index);
        if (inst.paid)                             revert InstallmentAlreadyPaid();
        if (block.timestamp < inst.dueDate)        revert InstallmentNotDue();

        dealEscrow.creditInstallment(dealId, index, inst.amount);

        IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), inst.amount);

        uint256 protocolAmt = (protocolFeeBps > 0 && treasury != address(0))
            ? inst.amount * protocolFeeBps / 10000 : 0;
        uint256 sellerAmt   = inst.amount - protocolAmt;

        if (protocolAmt > 0) _claimable[treasury][paymentToken]   += protocolAmt;
        _claimable[sellingClub][paymentToken] += sellerAmt;

        emit InstallmentPaid(dealId, index, inst.amount);
    }

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

    function flagOverdue(uint256 dealId, uint8 index) external onlyRole(LEAGUE_ROLE) {
        (
            ,,,
            uint8 installmentCount,
            ,
            uint8 state
        ) = dealEscrow.getInstallmentMeta(dealId);

        if (state != DEAL_COMPLETED)               revert WrongDealState();
        if (index == 0 || index >= installmentCount) revert InvalidIndex();

        TransferTypes.Installment memory inst = dealEscrow.getInstallment(dealId, index);
        if (inst.paid)                             revert InstallmentAlreadyPaid();
        if (block.timestamp <= inst.dueDate)       revert InstallmentNotOverdue();

        emit InstallmentOverdue(dealId, index, inst.dueDate);
    }

    function claim(address token) external nonReentrant {
        uint256 amt = _claimable[msg.sender][token];
        if (amt == 0) revert NothingToClaim();
        _claimable[msg.sender][token] = 0;
        IERC20(token).safeTransfer(msg.sender, amt);
        emit Claimed(msg.sender, token, amt);
    }

    function claimable(address account, address token) external view returns (uint256) {
        return _claimable[account][token];
    }
}
