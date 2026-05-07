// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IPlayerRegistry.sol";

/**
 * @title TransferLib
 * @author Transferium Protocol
 * @notice External library containing the heaviest logic from TransferEscrow.
 *
 * @dev Deployed separately so its bytecode does not count toward TransferEscrow's
 *      24KB EIP-170 limit. All functions are external — they execute in the
 *      context of the calling contract via DELEGATECALL.
 *
 *      Security note: external library functions share the caller's storage
 *      layout via delegatecall. The structs and mappings passed as parameters
 *      must match the exact storage layout in TransferEscrow. We pass explicit
 *      values rather than storage pointers where possible to keep this safe.
 */
library TransferLib {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS_DENOMINATOR = 10_000;

    // ─── Structs mirrored from TransferEscrow ─────────────────────────────────
    // I mirror only the fields the library actually reads or writes.

    struct SettlementParams {
        uint256 playerId;
        address sellingClub;
        address buyingClub;
        address paymentToken;
        uint256 transferFee;
        uint256 sellOnBps;
        address sellOnRecipient;
        uint256 sellerAgentBps;
        address sellerAgent;
        uint256 buyerAgentBps;
        address buyerAgent;
        uint256 protocolFeeBps;
        address treasury;
    }

    struct CancellationParams {
        uint256 playerId;
        address buyingClub;
        address sellingClub;
        address paymentToken;
        uint256 transferFee;
        uint256 salaryGuaranteeAmount;
        uint256 hijackDeposit;
        address hijackDepositClub;
        bool    wasFunded;       // true if deal reached FUNDED or DISPUTE_WINDOW
        bool    hasHijackBid;    // true if an unaccepted hijack bid exists
        address hijackBidClub;
        uint256 hijackBidFee;
    }

    // ─── Events — must match exactly what TransferEscrow declares ─────────────
    // I declare them here so the library can emit them. Solidity emits events
    // from the calling contract's address regardless of where they are declared.
    event DealCompleted(uint256 indexed dealId, uint256 indexed playerId, address indexed newClub);

    /**
     * @notice Distribute transfer fee to all parties and transfer the player NFT.
     * @dev All claimable credits are accumulated in the passed mapping.
     *      NFT transfer is the last external call — strict CEI pattern.
     *
     * Fee order: protocol fee -> sell-on -> seller agent -> buyer agent -> remainder to seller.
     * All fees calculated from gross transferFee, not compounded.
     * Integer division dust goes to selling club as remainder — by design.
     */
    function distributeFees(
        SettlementParams memory p,
        mapping(address => mapping(address => uint256)) storage claimable,
        IPlayerRegistry registry,
        uint256 dealId
    ) external {
        uint256 fee       = p.transferFee;
        uint256 remaining = fee;

        // I deduct protocol fee first — smallest deduction, fewest rounding issues
        if (p.protocolFeeBps > 0 && p.treasury != address(0)) {
            uint256 protocolFee = (fee * p.protocolFeeBps) / BPS_DENOMINATOR;
            remaining -= protocolFee;
            claimable[p.treasury][p.paymentToken] += protocolFee;
        }

        // I deduct sell-on clause
        if (p.sellOnBps > 0 && p.sellOnRecipient != address(0)) {
            uint256 amt = (fee * p.sellOnBps) / BPS_DENOMINATOR;
            remaining  -= amt;
            claimable[p.sellOnRecipient][p.paymentToken] += amt;
        }

        // I deduct seller agent fee
        if (p.sellerAgentBps > 0 && p.sellerAgent != address(0)) {
            uint256 amt = (fee * p.sellerAgentBps) / BPS_DENOMINATOR;
            remaining  -= amt;
            claimable[p.sellerAgent][p.paymentToken] += amt;
        }

        // I deduct buyer agent fee
        if (p.buyerAgentBps > 0 && p.buyerAgent != address(0)) {
            uint256 amt = (fee * p.buyerAgentBps) / BPS_DENOMINATOR;
            remaining  -= amt;
            claimable[p.buyerAgent][p.paymentToken] += amt;
        }

        // I send remainder to selling club
        claimable[p.sellingClub][p.paymentToken] += remaining;

        // I transfer the player NFT last — all state and claimable updates complete
        registry.escrowTransfer(p.playerId, p.sellingClub, p.buyingClub);

        emit DealCompleted(dealId, p.playerId, p.buyingClub);
    }

    /**
     * @notice Process all refunds when a deal is cancelled.
     * @dev Returns amounts to credit so TransferEscrow can update its claimable
     *      mapping — we cannot write to storage mappings passed as calldata.
     *
     *      Refund logic:
     *      - If deal was FUNDED: refund buying club the full transfer fee + salary guarantee
     *      - If an unaccepted hijack bid exists: refund hijack club
     *      - If a hijack deposit was carried in the deal: refund that club
     */
    function computeRefunds(CancellationParams memory p)
        external
        pure
        returns (
            address refundClub,
            uint256 refundAmount,
            address hijackRefundClub,
            uint256 hijackRefundAmount,
            address depositRefundClub,
            uint256 depositRefundAmount
        )
    {
        // I refund funded amounts if deal reached FUNDED or DISPUTE_WINDOW
        if (p.wasFunded) {
            refundClub   = p.buyingClub;
            refundAmount = p.transferFee + p.salaryGuaranteeAmount;
        }

        // I refund unaccepted hijack bid
        if (p.hasHijackBid) {
            hijackRefundClub   = p.hijackBidClub;
            hijackRefundAmount = p.hijackBidFee;
        }

        // I refund hijack deposit carried in deal after acceptHijackBid
        // Only refund if deal was not yet funded — funded case handled above
        if (p.hijackDeposit > 0 && p.hijackDepositClub != address(0) && !p.wasFunded) {
            depositRefundClub   = p.hijackDepositClub;
            depositRefundAmount = p.hijackDeposit;
        }
    }
}
