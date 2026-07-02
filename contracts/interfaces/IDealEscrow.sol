// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../types/TransferTypes.sol";

/**
 * @title  IDealEscrow
 * @notice Interface used by TransferEscrow and CompetingBidManager to interact
 *         with DealEscrow. Hijack functions removed — competing bids are now
 *         handled entirely by CompetingBidManager via the new callback set.
 */
interface IDealEscrow {

    // Re-exported so callers don't need a circular import
    enum DealState {
        NONE,                         // 0
        OFFER_CREATED,                // 1
        BID_SUBMITTED,                // 2
        NEGOTIATING,                  // 3
        BID_ACCEPTED,                 // 4
        AWAITING_PLAYER_CONSENT,      // 5
        AWAITING_MEDICAL,             // 6
        MEDICAL_RENEGOTIATION,        // 7
        MEDICAL_DISPUTE,              // 8
        AWAITING_THIRD_PARTY_MEDICAL, // 9
        MUTUAL_CANCEL_PROPOSED,       // 10
        FUNDING_PENDING,              // 11
        FUNDED,                       // 12
        DISPUTE_WINDOW,               // 13
        COMPLETED,                    // 14
        CANCELLED                     // 15
    }

    // Fields TransferEscrow needs for deal validation
    struct DealView {
        bool      exists;
        address   sellingClub;
        address   buyingClub;
        address   paymentToken;
        uint256   transferFee;
        DealState state;
        uint256   stateDeadline;
    }

    // ─── Core ─────────────────────────────────────────────────────────────────

    function initializeDeal(
        TransferTypes.DealInitParams calldata params,
        TransferTypes.AddOn[]        calldata addOns
    ) external returns (uint256 dealId);

    function getDealView(uint256 dealId) external view returns (DealView memory);
    function getPlayerDeal(uint256 playerId) external view returns (uint256);

    // ─── processExpiry callbacks (TRANSFER_ESCROW_ROLE only) ──────────────────

    function extCancel(uint256 dealId, uint8 reason) external;
    function extClearMutualCancel(uint256 dealId) external;
    function extSettle(uint256 dealId) external;
    function extWalkAwayPenalty(uint256 dealId) external;
    function extRescueBonus(uint256 dealId, address dest) external;
    function extWithdrawAddOn(uint256 dealId, address buyer, uint256 amount) external;

    function getExpiryView(uint256 dealId) external view returns (
        bool     exists,
        bool     frozen,
        uint8    state,
        uint256  stateDeadline,
        uint256  mutualCancelDeadline,
        address  mutualCancelProposer
    );

    function getInstallment(uint256 dealId, uint8 index) external view returns (TransferTypes.Installment memory);
    function getAddOnDeposit(uint256 dealId, address token) external view returns (uint256);

    // ─── CompetingBidManager callbacks (COMPETING_BID_MANAGER_ROLE only) ──────

    /**
     * @notice Switch buying club to Club C after seller accepts competing bid.
     *         Preserves originalBuyer (Club B) for compensation tracking.
     *         Sets state to FUNDING_PENDING.
     */
    function extActivateThirdParty(
        uint256 dealId,
        address thirdParty,
        uint256 newFee,
        uint256 buyerAgentBps,
        address buyerAgent,
        uint256 signingBonusMonths
    ) external;

    /**
     * @notice Settle a deal after Club C's medical passes.
     *         State must be AWAITING_THIRD_PARTY_MEDICAL.
     */
    function extSettleThirdParty(uint256 dealId) external;

    /**
     * @notice Credit Club B's counter-deposit toward their first installment.
     *         Tokens must already be in DealEscrow. State must be FUNDING_PENDING.
     */
    function extCreditCounterDeposit(uint256 dealId, uint256 amount) external;

    /**
     * @notice Credits amount to recipient's claimable balance.
     *         Used by CompetingBidManager to distribute deposits without
     *         moving tokens out of DealEscrow.
     */
    function extCreditClaimable(address recipient, address token, uint256 amount) external;
}
