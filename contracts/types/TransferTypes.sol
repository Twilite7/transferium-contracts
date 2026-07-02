// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title  TransferTypes
 * @author Transferium Protocol
 * @notice Shared types used across TransferEscrow, DealEscrow and
 *         CompetingBidManager. Centralising them prevents enum drift.
 *
 * DealState values (uint8):
 *   0  NONE
 *   1  OFFER_CREATED
 *   2  BID_SUBMITTED
 *   3  NEGOTIATING
 *   4  BID_ACCEPTED
 *   5  AWAITING_PLAYER_CONSENT
 *   6  AWAITING_MEDICAL          ← merged medical + competing-bid window
 *   7  MEDICAL_RENEGOTIATION
 *   8  MEDICAL_DISPUTE
 *   9  AWAITING_THIRD_PARTY_MEDICAL  ← Club C is now the buyer
 *  10  MUTUAL_CANCEL_PROPOSED
 *  11  FUNDING_PENDING
 *  12  FUNDED
 *  13  DISPUTE_WINDOW
 *  14  COMPLETED
 *  15  CANCELLED
 *
 * IMPORTANT: processExpiry in TransferEscrow uses hard-coded uint8 values
 * that mirror this ordering exactly. Any future reordering requires a
 * matching update there.
 */
library TransferTypes {

    // ─── Structs ──────────────────────────────────────────────────────────────

    struct Installment {
        uint256 amount;   // token units (6 decimals for EURC)
        uint256 dueDate;  // unix timestamp when payment is due
        bool    paid;
    }

    struct AddOn {
        string  description;
        uint256 amount;
        bool    toPlayer;  // true → player wallet, false → selling club
        bool    triggered;
    }

    // ─── Enums ────────────────────────────────────────────────────────────────

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

    enum MedicalOutcome { NONE, PASSED, FAILED, CONCERN }

    // I use an enum for cancel reasons — uint8 on-chain, no string bytecode cost.
    enum CancelReason {
        NONE,                        // 0
        LEAGUE_DISPUTE_CANCELLED,    // 1
        MEDICAL_RENEGO_REJECTED,     // 2
        MUTUAL_CANCEL_AGREED,        // 3
        PLAYER_DECLINED,             // 4
        MEDICAL_FAILED,              // 5
        RENEGO_WINDOW_EXPIRED,       // 6
        BUYER_WALKED_AWAY,           // 7
        CONSENT_WINDOW_EXPIRED,      // 8
        MEDICAL_WINDOW_EXPIRED,      // 9
        THIRD_PARTY_MEDICAL_FAILED,  // 10
        RENEGO_NO_RESOLUTION,        // 11
        LEAGUE_DEADLINE_EXPIRED,     // 12
        FUNDING_WINDOW_EXPIRED,      // 13
        FORCE_CANCELLED              // 14
    }

    // ─── Deal initialisation params ───────────────────────────────────────────

    // I pass deal-init data as a struct to avoid stack-too-deep in initializeDeal.
    // minimumHijackIncrementBps removed — competing bids handled by CompetingBidManager.
    // consentWindowDuration removed — DealEscrow uses timers[0] directly.
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
        // Installment schedule — lengths must match; sum must equal transferFee
        uint256[] installmentAmounts;
        uint256[] installmentDueDates;
    }
}
