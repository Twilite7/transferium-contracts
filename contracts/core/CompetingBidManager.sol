// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IDealEscrow.sol";
import "../types/TransferTypes.sol";

/**
 * @title  CompetingBidManager
 * @author Transferium Protocol
 * @notice Manages competing bids on in-progress deals during the AWAITING_MEDICAL window.
 *
 * Flow:
 *  1. Club C calls submitCompetingBid() — deposits competingDepositBps% into DealEscrow.
 *     Replaces any prior unaccepted bid (previous deposit returned via claimable).
 *  2. Club C can call upCompetingBid() to raise their offer (pays extra deposit).
 *  3. Club A calls acceptCompetingBid() — starts Club B's matching window.
 *     Or Club A calls ignoreCompetingBid() — deposit returned to Club C via claimable.
 *  4. Club B calls matchCompetingBid() within the window — deposits counterDepositBps%.
 *  5a. Club A calls confirmSwitch() — Club C becomes new buyer.
 *      Club C's full deposit credited to Club B as compensation.
 *      Club B's counter-deposit returned via claimable.
 *  5b. Club A calls confirmOriginal() after Club B matches — Club B stays.
 *      Club C's deposit returned. Club B's counter-deposit credited toward
 *      first installment via extCreditCounterDeposit.
 *  6. If Club B's medical FAILED and a resolved competing bid exists,
 *     call activateAfterFailedMedical() — Club C takes over, Club B compensated.
 *
 * Security:
 *  - All token custody stays in DealEscrow — this contract never holds funds.
 *  - CEI ordering on every state-changing function.
 *  - nonReentrant on all functions that trigger token movements.
 *  - Custom errors only.
 *  - No unbounded loops.
 */
contract CompetingBidManager is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Immutables ───────────────────────────────────────────────────────────

    IDealEscrow public immutable dealEscrow;

    // ─── Config ───────────────────────────────────────────────────────────────

    uint256 public competingDepositBps;     // default 1000 = 10%
    uint256 public counterDepositBps;       // default 1000 = 10%
    uint256 public matchingWindow;          // default 24 hours
    uint256 public thirdPartyFundingWindow; // default 72 hours

    address public admin;

    // ─── Constants ────────────────────────────────────────────────────────────

    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant MAX_DEPOSIT_BPS = 3_000; // 30% hard cap
    uint256 private constant MAX_AGENT_BPS   =   300; // 3% agent fee cap
    // DealState values (must mirror TransferTypes.DealState exactly)
    uint8   private constant STATE_FUNDING_PENDING   = 11; // competing bids active here
    uint8   private constant STATE_CANCELLED         = 15;

    // ─── Storage ──────────────────────────────────────────────────────────────

    struct CompetingBid {
        address competingClub;      // Club C
        uint256 proposedFee;        // Club C's current offer
        uint256 deposit;            // amount in DealEscrow from Club C
        uint256 buyerAgentBps;
        address buyerAgent;
        uint256 signingBonusMonths;
        uint256 acceptedAt;         // 0 = not yet accepted by Club A
        uint256 matchDeadline;      // acceptedAt + matchingWindow
        bool    clubBMatched;       // Club B deposited counter
        uint256 clubBDeposit;       // Club B's counter-deposit amount
        address clubBAddress;       // snapshot of buyingClub when bid accepted
        address paymentToken;       // token used for this deal
    }

    mapping(uint256 => CompetingBid) private _bids; // dealId → bid

    // ─── Events ───────────────────────────────────────────────────────────────

    event CompetingBidSubmitted(uint256 indexed dealId, address indexed competingClub, uint256 fee);
    event CompetingBidUpped(uint256 indexed dealId, address indexed competingClub, uint256 newFee, uint256 newDeposit);
    event CompetingBidAccepted(uint256 indexed dealId, address indexed competingClub, uint256 matchDeadline);
    event CompetingBidIgnored(uint256 indexed dealId, address indexed competingClub);
    event ClubBMatched(uint256 indexed dealId, address indexed clubB, uint256 counterDeposit);
    event SwitchConfirmed(uint256 indexed dealId, address indexed newBuyer, address indexed clubBCompensated, uint256 compensation);
    event OriginalConfirmed(uint256 indexed dealId, address indexed buyer, uint256 clubCRefunded);
    event ActivatedAfterMedicalFailure(uint256 indexed dealId, address indexed thirdParty, address indexed clubBCompensated);
    event AdminChanged(address indexed newAdmin);
    event ConfigUpdated(string param, uint256 value);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error NotAdmin();
    error DealNotFound();
    error WrongDealState();
    error NotSellingClub();
    error NotOriginalBuyer();
    error NotCompetingClub();
    error CannotBidOnOwnDeal();
    error BidAlreadyAccepted();
    error NoBidExists();
    error BidNotAccepted();
    error MatchWindowStillOpen();
    error MatchWindowClosed();
    error AlreadyMatched();
    error ClubBNotMatched();
    error InvalidAmount();
    error InvalidAddress();
    error InvalidBps();
    error FeeMustIncrease();

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(address _dealEscrow, address _admin) {
        if (_dealEscrow == address(0)) revert InvalidAddress();
        if (_admin      == address(0)) revert InvalidAddress();
        dealEscrow              = IDealEscrow(_dealEscrow);
        admin                   = _admin;
        competingDepositBps     = 1_000; // 10%
        counterDepositBps       = 1_000; // 10%
        matchingWindow          = 24 hours;
        thirdPartyFundingWindow = 72 hours;
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert InvalidAddress();
        admin = newAdmin;
        emit AdminChanged(newAdmin);
    }

    function setCompetingDepositBps(uint256 bps) external onlyAdmin {
        if (bps == 0 || bps > MAX_DEPOSIT_BPS) revert InvalidBps();
        competingDepositBps = bps;
        emit ConfigUpdated("competingDepositBps", bps);
    }

    function setCounterDepositBps(uint256 bps) external onlyAdmin {
        if (bps == 0 || bps > MAX_DEPOSIT_BPS) revert InvalidBps();
        counterDepositBps = bps;
        emit ConfigUpdated("counterDepositBps", bps);
    }

    function setMatchingWindow(uint256 secs) external onlyAdmin {
        if (secs == 0) revert InvalidAmount();
        matchingWindow = secs;
        emit ConfigUpdated("matchingWindow", secs);
    }

    function setThirdPartyFundingWindow(uint256 secs) external onlyAdmin {
        if (secs == 0) revert InvalidAmount();
        thirdPartyFundingWindow = secs;
        emit ConfigUpdated("thirdPartyFundingWindow", secs);
    }

    // ─── Club C: Submit ───────────────────────────────────────────────────────

    /**
     * @notice Submit a competing bid during the AWAITING_MEDICAL window.
     * @dev    Pulls competingDepositBps% of fee from Club C into DealEscrow.
     *         If an unaccepted competing bid already exists, it is replaced and
     *         the previous deposit credited back to the previous Club C via claimable.
     */
    function submitCompetingBid(
        uint256 dealId,
        uint256 fee,
        uint256 buyerAgentBps,
        address buyerAgent,
        uint256 signingBonusMonths
    ) external nonReentrant {
        IDealEscrow.DealView memory dv = dealEscrow.getDealView(dealId);
        if (!dv.exists)                          revert DealNotFound();
        if (uint8(dv.state) != STATE_FUNDING_PENDING) revert WrongDealState();
        if (msg.sender == dv.sellingClub)        revert CannotBidOnOwnDeal();
        if (msg.sender == dv.buyingClub)         revert CannotBidOnOwnDeal();
        if (fee == 0)                             revert InvalidAmount();
        if (buyerAgentBps > MAX_AGENT_BPS)       revert InvalidBps();
        if (buyerAgentBps > 0 && buyerAgent == address(0)) revert InvalidAddress();

        CompetingBid storage existing = _bids[dealId];

        // I reject if there is already an accepted bid — Club A must resolve it first
        if (existing.competingClub != address(0) && existing.acceptedAt != 0) {
            revert BidAlreadyAccepted();
        }

        // I return any previous unaccepted deposit before overwriting
        if (existing.competingClub != address(0) && existing.deposit > 0) {
            address prevClub    = existing.competingClub;
            address prevToken   = existing.paymentToken;
            uint256 prevDeposit = existing.deposit;
            // CEI: zero out before external call
            existing.deposit = 0;
            dealEscrow.extCreditClaimable(prevClub, prevToken, prevDeposit);
        }

        uint256 deposit = (fee * competingDepositBps) / BPS_DENOMINATOR;
        if (deposit == 0) revert InvalidAmount();

        // CEI: write state before pulling tokens
        _bids[dealId] = CompetingBid({
            competingClub:      msg.sender,
            proposedFee:        fee,
            deposit:            deposit,
            buyerAgentBps:      buyerAgentBps,
            buyerAgent:         buyerAgent,
            signingBonusMonths: signingBonusMonths,
            acceptedAt:         0,
            matchDeadline:      0,
            clubBMatched:       false,
            clubBDeposit:       0,
            clubBAddress:       address(0),
            paymentToken:       dv.paymentToken
        });

        IERC20(dv.paymentToken).safeTransferFrom(msg.sender, address(dealEscrow), deposit);

        emit CompetingBidSubmitted(dealId, msg.sender, fee);
    }

    /**
     * @notice Club C increases their fee before Club A accepts.
     * @dev    Pulls the incremental deposit. Fee can only increase.
     */
    function upCompetingBid(uint256 dealId, uint256 newFee) external nonReentrant {
        IDealEscrow.DealView memory dv = dealEscrow.getDealView(dealId);
        if (!dv.exists)                                revert DealNotFound();
        if (uint8(dv.state) != STATE_FUNDING_PENDING) revert WrongDealState();

        CompetingBid storage bid = _bids[dealId];
        if (bid.competingClub == address(0))    revert NoBidExists();
        if (bid.competingClub != msg.sender)    revert NotCompetingClub();
        if (bid.acceptedAt != 0)                revert BidAlreadyAccepted();
        if (newFee <= bid.proposedFee)          revert FeeMustIncrease();

        uint256 newDeposit    = (newFee * competingDepositBps) / BPS_DENOMINATOR;
        uint256 extraRequired = newDeposit - bid.deposit;

        // CEI: update state before pulling tokens
        bid.proposedFee = newFee;
        bid.deposit     = newDeposit;

        IERC20(dv.paymentToken).safeTransferFrom(msg.sender, address(dealEscrow), extraRequired);

        emit CompetingBidUpped(dealId, msg.sender, newFee, newDeposit);
    }

    // ─── Club A: Accept / Ignore / Confirm ───────────────────────────────────

    /**
     * @notice Club A accepts the competing bid. Starts Club B's matching window.
     */
    function acceptCompetingBid(uint256 dealId) external {
        IDealEscrow.DealView memory dv = dealEscrow.getDealView(dealId);
        if (!dv.exists)                                revert DealNotFound();
        if (uint8(dv.state) != STATE_FUNDING_PENDING) revert WrongDealState();
        if (msg.sender != dv.sellingClub)              revert NotSellingClub();

        CompetingBid storage bid = _bids[dealId];
        if (bid.competingClub == address(0)) revert NoBidExists();
        if (bid.acceptedAt != 0)             revert BidAlreadyAccepted();

        bid.acceptedAt    = block.timestamp;
        bid.matchDeadline = block.timestamp + matchingWindow;
        bid.clubBAddress  = dv.buyingClub;

        emit CompetingBidAccepted(dealId, bid.competingClub, bid.matchDeadline);
    }

    /**
     * @notice Club A ignores the competing bid. Returns Club C's deposit via claimable.
     */
    function ignoreCompetingBid(uint256 dealId) external nonReentrant {
        IDealEscrow.DealView memory dv = dealEscrow.getDealView(dealId);
        if (!dv.exists)                                revert DealNotFound();
        if (uint8(dv.state) != STATE_FUNDING_PENDING) revert WrongDealState();
        if (msg.sender != dv.sellingClub)              revert NotSellingClub();

        CompetingBid storage bid = _bids[dealId];
        if (bid.competingClub == address(0)) revert NoBidExists();
        if (bid.acceptedAt != 0)             revert BidAlreadyAccepted();

        address club    = bid.competingClub;
        uint256 deposit = bid.deposit;
        address token   = bid.paymentToken;

        // CEI: clear before external call
        delete _bids[dealId];

        dealEscrow.extCreditClaimable(club, token, deposit);

        emit CompetingBidIgnored(dealId, club);
    }

    /**
     * @notice Club A confirms switch to Club C after matching window resolves.
     * @dev    Callable when: (a) matching window expired without Club B matching,
     *         OR (b) Club B matched but Club A chooses Club C anyway.
     *         Club C's deposit credited entirely to Club B as compensation.
     *         Club B's counter-deposit (if any) returned via claimable.
     */
    function confirmSwitch(uint256 dealId) external nonReentrant {
        IDealEscrow.DealView memory dv = dealEscrow.getDealView(dealId);
        if (!dv.exists)                                revert DealNotFound();
        if (uint8(dv.state) != STATE_FUNDING_PENDING) revert WrongDealState();
        if (msg.sender != dv.sellingClub)              revert NotSellingClub();

        CompetingBid storage bid = _bids[dealId];
        if (bid.competingClub == address(0)) revert NoBidExists();
        if (bid.acceptedAt == 0)             revert BidNotAccepted();
        // Matching window must be closed or Club B must have matched
        if (block.timestamp < bid.matchDeadline && !bid.clubBMatched) {
            revert MatchWindowStillOpen();
        }

        address competingClub  = bid.competingClub;
        address clubB          = bid.clubBAddress;
        uint256 cDeposit       = bid.deposit;
        uint256 bDeposit       = bid.clubBDeposit;
        uint256 newFee         = bid.proposedFee;
        uint256 agentBps       = bid.buyerAgentBps;
        address agent          = bid.buyerAgent;
        uint256 bonusMonths    = bid.signingBonusMonths;
        address token          = bid.paymentToken;

        // CEI: clear state before all external calls
        delete _bids[dealId];

        // Club C's full deposit → Club B as compensation (always, unconditionally)
        dealEscrow.extCreditClaimable(clubB, token, cDeposit);

        // Return Club B's counter-deposit if they matched
        if (bDeposit > 0) {
            dealEscrow.extCreditClaimable(clubB, token, bDeposit);
        }

        // Activate Club C as new buyer
        dealEscrow.extActivateThirdParty(
            dealId, competingClub, newFee, agentBps, agent, bonusMonths
        );

        emit SwitchConfirmed(dealId, competingClub, clubB, cDeposit);
    }

    /**
     * @notice Club A confirms original deal with Club B after Club B matches.
     * @dev    Club C's deposit returned. Club B's counter-deposit credited toward
     *         their first installment via extCreditCounterDeposit.
     */
    function confirmOriginal(uint256 dealId) external nonReentrant {
        IDealEscrow.DealView memory dv = dealEscrow.getDealView(dealId);
        if (!dv.exists)                                revert DealNotFound();
        if (uint8(dv.state) != STATE_FUNDING_PENDING) revert WrongDealState();
        if (msg.sender != dv.sellingClub)              revert NotSellingClub();

        CompetingBid storage bid = _bids[dealId];
        if (bid.competingClub == address(0)) revert NoBidExists();
        if (bid.acceptedAt == 0)             revert BidNotAccepted();
        if (!bid.clubBMatched)               revert ClubBNotMatched();

        address competingClub = bid.competingClub;
        uint256 cDeposit      = bid.deposit;
        uint256 bDeposit      = bid.clubBDeposit;
        address token         = bid.paymentToken;

        // CEI: clear before external calls
        delete _bids[dealId];

        // Return Club C's deposit
        dealEscrow.extCreditClaimable(competingClub, token, cDeposit);

        // Credit Club B's counter-deposit toward their first installment
        if (bDeposit > 0) {
            dealEscrow.extCreditCounterDeposit(dealId, bDeposit);
        }

        emit OriginalConfirmed(dealId, dv.buyingClub, cDeposit);
    }

    // ─── Club B: Match ────────────────────────────────────────────────────────

    /**
     * @notice Club B matches the competing bid within the matching window.
     * @dev    Pulls counterDepositBps% of Club B's original agreed fee into DealEscrow.
     */
    function matchCompetingBid(uint256 dealId) external nonReentrant {
        IDealEscrow.DealView memory dv = dealEscrow.getDealView(dealId);
        if (!dv.exists)                                revert DealNotFound();
        if (uint8(dv.state) != STATE_FUNDING_PENDING) revert WrongDealState();

        CompetingBid storage bid = _bids[dealId];
        if (bid.competingClub == address(0))          revert NoBidExists();
        if (bid.acceptedAt == 0)                      revert BidNotAccepted();
        if (block.timestamp > bid.matchDeadline)      revert MatchWindowClosed();
        if (bid.clubBMatched)                         revert AlreadyMatched();
        if (msg.sender != bid.clubBAddress)           revert NotOriginalBuyer();

        uint256 counterDeposit = (dv.transferFee * counterDepositBps) / BPS_DENOMINATOR;
        if (counterDeposit == 0) revert InvalidAmount();

        // CEI: update state before pulling tokens
        bid.clubBMatched = true;
        bid.clubBDeposit = counterDeposit;

        IERC20(dv.paymentToken).safeTransferFrom(msg.sender, address(dealEscrow), counterDeposit);

        emit ClubBMatched(dealId, msg.sender, counterDeposit);
    }

    // ─── Activation after failed medical ─────────────────────────────────────

    /**
     * @notice Activate Club C after Club B's medical fails.
     * @dev    Callable by anyone once deal is CANCELLED and a resolved competing bid
     *         exists (accepted + matching window closed or Club B matched).
     *         Club B receives Club C's full deposit as compensation.
     */
    function activateAfterFailedMedical(uint256 dealId) external nonReentrant {
        (bool exists, bool frozen, uint8 state,,, ) = dealEscrow.getExpiryView(dealId);
        if (!exists)  revert DealNotFound();
        if (frozen)   revert WrongDealState();
        // Deal must be cancelled (medical failed) or still in AWAITING_MEDICAL
        if (state != STATE_CANCELLED && state != STATE_FUNDING_PENDING) revert WrongDealState();

        CompetingBid storage bid = _bids[dealId];
        if (bid.competingClub == address(0)) revert NoBidExists();
        if (bid.acceptedAt == 0)             revert BidNotAccepted();
        // Matching window must be resolved
        if (block.timestamp < bid.matchDeadline && !bid.clubBMatched) {
            revert MatchWindowStillOpen();
        }

        IDealEscrow.DealView memory dv = dealEscrow.getDealView(dealId);

        address competingClub = bid.competingClub;
        address clubB         = bid.clubBAddress;
        uint256 cDeposit      = bid.deposit;
        uint256 newFee        = bid.proposedFee;
        uint256 agentBps      = bid.buyerAgentBps;
        address agent         = bid.buyerAgent;
        uint256 bonusMonths   = bid.signingBonusMonths;
        address token         = bid.paymentToken;

        // CEI: clear before external calls
        delete _bids[dealId];

        // Club C's deposit → Club B as compensation (unconditional)
        dealEscrow.extCreditClaimable(clubB, token, cDeposit);

        // Activate Club C — resets deal from CANCELLED to FUNDING_PENDING
        dealEscrow.extActivateThirdParty(
            dealId, competingClub, newFee, agentBps, agent, bonusMonths
        );

        emit ActivatedAfterMedicalFailure(dealId, competingClub, clubB);
    }

    // ─── Process expiry (matching window) ────────────────────────────────────

    /**
     * @notice Auto-activate Club C when the matching window expires
     *         and Club B did not match.
     * @dev    Anyone can call. Club B receives compensation from Club C's deposit.
     */
    function processMatchingExpiry(uint256 dealId) external nonReentrant {
        IDealEscrow.DealView memory dv = dealEscrow.getDealView(dealId);
        if (!dv.exists)                                revert DealNotFound();
        if (uint8(dv.state) != STATE_FUNDING_PENDING) revert WrongDealState();

        CompetingBid storage bid = _bids[dealId];
        if (bid.competingClub == address(0)) revert NoBidExists();
        if (bid.acceptedAt == 0)             revert BidNotAccepted();
        if (bid.clubBMatched)                revert AlreadyMatched(); // use confirmSwitch
        if (block.timestamp <= bid.matchDeadline) revert MatchWindowStillOpen();

        address competingClub = bid.competingClub;
        address clubB         = bid.clubBAddress;
        uint256 cDeposit      = bid.deposit;
        uint256 newFee        = bid.proposedFee;
        uint256 agentBps      = bid.buyerAgentBps;
        address agent         = bid.buyerAgent;
        uint256 bonusMonths   = bid.signingBonusMonths;
        address token         = bid.paymentToken;

        // CEI: clear before external calls
        delete _bids[dealId];

        // Compensate Club B
        dealEscrow.extCreditClaimable(clubB, token, cDeposit);

        // Activate Club C
        dealEscrow.extActivateThirdParty(
            dealId, competingClub, newFee, agentBps, agent, bonusMonths
        );

        emit SwitchConfirmed(dealId, competingClub, clubB, cDeposit);
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    function getCompetingBid(uint256 dealId) external view returns (CompetingBid memory) {
        return _bids[dealId];
    }

    function isMatchingWindowOpen(uint256 dealId) external view returns (bool) {
        CompetingBid storage bid = _bids[dealId];
        return bid.acceptedAt != 0 && block.timestamp <= bid.matchDeadline;
    }

    /// @notice Returns true if there is an accepted, unresolved competing bid.
    /// @dev    Called by DealEscrow.fundDeal to block Club B from funding
    ///         while Club A has accepted a competing bid they havent resolved.
    function hasActiveBid(uint256 dealId) external view returns (bool) {
        CompetingBid storage bid = _bids[dealId];
        return bid.competingClub != address(0) && bid.acceptedAt != 0;
    }
}
