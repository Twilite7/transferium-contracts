// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title TransferTypes
 * @author Transferium Protocol
 * @notice Shared types used by both TransferEscrow and DealEscrow.
 *         Keeping them in one place prevents divergence between contracts.
 */
library TransferTypes {

    struct Installment {
        uint256 amount;   // token units (6 decimals for EURC)
        uint256 dueDate;  // unix timestamp when payment is due
        bool    paid;
    }

    struct AddOn {
        string  description;
        uint256 amount;
        bool    toPlayer;   // true = routes to player wallet, false = to selling club
        bool    triggered;
    }

    enum DealState {
        NONE,
        OFFER_CREATED,
        BID_SUBMITTED,
        NEGOTIATING,
        BID_ACCEPTED,
        AWAITING_PLAYER_CONSENT,
        AWAITING_TRANSFER_MEDICAL,
        MEDICAL_RENEGOTIATION,
        MEDICAL_DISPUTE,
        HIJACK_WINDOW,
        AWAITING_HIJACK_CONSENT,
        AWAITING_HIJACK_MEDICAL,
        MUTUAL_CANCEL_PROPOSED,
        FUNDING_PENDING,
        FUNDED,
        DISPUTE_WINDOW,
        COMPLETED,
        CANCELLED
        // FROZEN removed — freeze is a flag on Deal struct, not a state transition
    }

    enum MedicalOutcome { NONE, PASSED, FAILED, CONCERN }

    // I use an enum for cancel reasons — uint8 on-chain, no string bytecode cost.
    // Frontend maps values to human-readable messages via parseError.ts.
    enum CancelReason {
        NONE,
        LEAGUE_DISPUTE_CANCELLED,
        MEDICAL_RENEGO_REJECTED,
        MUTUAL_CANCEL_AGREED,
        PLAYER_DECLINED,
        MEDICAL_FAILED,
        RENEGO_WINDOW_EXPIRED,
        BUYER_WALKED_AWAY,
        CONSENT_WINDOW_EXPIRED,
        MEDICAL_WINDOW_EXPIRED,
        HIJACK_MEDICAL_STALL,
        RENEGO_NO_RESOLUTION,
        LEAGUE_DEADLINE_EXPIRED,
        FUNDING_WINDOW_EXPIRED,
        FORCE_CANCELLED
    }

    // I use a struct to pass deal init params — avoids stack-too-deep on initializeDeal.
    struct DealInitParams {
        uint256 offerId;
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
        uint256 signingBonusMonths;
        uint256 signingBonusAmount;
        uint256 minimumHijackIncrementBps;
        uint256 consentWindowDuration;
        // Installment payment schedule — lengths must match, sum must equal transferFee
        uint256[] installmentAmounts;
        uint256[] installmentDueDates;
    }
}
