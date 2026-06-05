// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../types/TransferTypes.sol";

/**
 * @title IDealEscrow
 * @notice Interface used by TransferEscrow to hand off accepted deals and hijack bids.
 */
interface IDealEscrow {

    // I re-export DealState so TransferEscrow can reference it without circular imports
    enum DealState {
        NONE, OFFER_CREATED, BID_SUBMITTED, NEGOTIATING, BID_ACCEPTED,
        AWAITING_PLAYER_CONSENT, AWAITING_TRANSFER_MEDICAL, MEDICAL_RENEGOTIATION,
        MEDICAL_DISPUTE, HIJACK_WINDOW, AWAITING_HIJACK_CONSENT, AWAITING_HIJACK_MEDICAL,
        MUTUAL_CANCEL_PROPOSED, FUNDING_PENDING, FUNDED, DISPUTE_WINDOW,
        COMPLETED, CANCELLED
    }

    // I expose only the fields TransferEscrow needs for hijack bid validation
    struct DealView {
        bool      exists;
        address   sellingClub;
        address   buyingClub;
        address   paymentToken;
        uint256   transferFee;
        uint256   minimumHijackIncrementBps;
        DealState state;
        uint256   stateDeadline;
    }

    /**
     * @notice Called by TransferEscrow when a bid is accepted.
     *         Creates the deal record and emits PlayerConsentRequested.
     * @dev Caller must hold TRANSFER_ESCROW_ROLE.
     */
    function initializeDeal(
        TransferTypes.DealInitParams calldata params,
        TransferTypes.AddOn[]        calldata addOns
    ) external returns (uint256 dealId);

    /**
     * @notice Returns minimal deal data needed by TransferEscrow for hijack validation.
     */
    function getDealView(uint256 dealId) external view returns (DealView memory);

    /**
     * @notice Returns the active dealId for a player, 0 if none.
     * @dev TransferEscrow calls this in createOffer to block duplicate processes.
     */
    function getPlayerDeal(uint256 playerId) external view returns (uint256);

    /**
     * @notice Records an incoming hijack bid. Previous hijacker refunded via _claimable.
     * @dev TRANSFER_ESCROW_ROLE only. Tokens already in DealEscrow before calling.
     */
    function receiveHijackBid(
        uint256 dealId,
        address buyingClub,
        uint256 transferFee,
        uint256 buyerAgentBps,
        address buyerAgent,
        uint256 signingBonusMonths
    ) external;

    // ─── processExpiry callbacks (TRANSFER_ESCROW_ROLE only) ──────────────────

    /**
     * @notice Cancel a deal from an external caller (processExpiry in TransferEscrow).
     * @dev TRANSFER_ESCROW_ROLE only.
     */
    function extCancel(uint256 dealId, uint8 reason) external;

    /**
     * @notice Advance HIJACK_WINDOW deal to FUNDING_PENDING.
     * @dev TRANSFER_ESCROW_ROLE only.
     */
    function extAdvanceToFunding(uint256 dealId) external;

    /**
     * @notice Clear an expired mutual cancel proposal.
     * @dev TRANSFER_ESCROW_ROLE only.
     */
    function extClearMutualCancel(uint256 dealId) external;

    /**
     * @notice Returns deal state fields needed by processExpiry in TransferEscrow.
     */
    function getExpiryView(uint256 dealId) external view returns (
        bool     exists,
        bool     frozen,
        uint8    state,
        uint256  stateDeadline,
        uint256  mutualCancelDeadline,
        address  mutualCancelProposer
    );

    // I expose settlement for processExpiry auto-complete path
    function extSettle(uint256 dealId) external;

    // ─── Installment support ──────────────────────────────────────────────────
    function getInstallment(uint256 dealId, uint8 index) external view returns (TransferTypes.Installment memory);
    /**
     * @notice Advance a MEDICAL_DISPUTE deal to HIJACK_WINDOW.
     * @dev newFee = 0 keeps original fee, non-zero overrides it.
     *      TRANSFER_ESCROW_ROLE only.
     */
    function extAdvanceToHijack(uint256 dealId, uint256 newFee) external;
    /**
     * @notice Cancel a deal when buying club walks away from renegotiation.
     * @dev No token credits — no funds are locked at MEDICAL_RENEGOTIATION.
     *      TRANSFER_ESCROW_ROLE only.
     */
    function extWalkAwayPenalty(uint256 dealId) external;
    function extRescueBonus(uint256 dealId, address dest) external;
    function extWithdrawAddOn(uint256 dealId, address buyer, uint256 amount) external;
    function getAddOnDeposit(uint256 dealId, address token) external view returns (uint256);
}
