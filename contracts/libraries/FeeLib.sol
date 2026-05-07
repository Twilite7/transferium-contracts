// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title FeeLib
 * @author Transferium Protocol
 * @notice Computes fee distribution amounts for transfer settlements.
 *
 * @dev External library — deployed separately so its bytecode does NOT count
 *      toward DealEscrow's 24KB EIP-170 limit. All logic here disappears
 *      from DealEscrow's compiled output and becomes a DELEGATECALL instead.
 *
 *      All fees are computed from the gross transfer fee, not compounded.
 *      Example: fee=100, protocol=0.5%, sellOn=5%, sellerAgent=2%, buyerAgent=2%
 *               remaining to seller = 100 - 0.5 - 5 - 2 - 2 = 90.5
 *      Integer division dust accumulates in sellerRemainder — by design,
 *      dust goes to the selling club as the last recipient.
 */
library FeeLib {
    // I define the error here so callers get a clear revert reason
    error FeesExceed100Pct();


    /**
     * @notice Compute all fee amounts from a gross transfer fee.
     * @param fee            Gross transfer fee in token units
     * @param protocolBps    Protocol fee in basis points
     * @param sellOnBps      Sell-on clause in basis points
     * @param sellerAgentBps Seller agent fee in basis points
     * @param buyerAgentBps  Buyer agent fee in basis points
     * @return protocolAmt    Amount for protocol treasury
     * @return sellOnAmt      Amount for sell-on recipient
     * @return sellerAgentAmt Amount for seller's agent
     * @return buyerAgentAmt  Amount for buyer's agent
     * @return sellerAmt      Remainder to selling club
     */
    function computeFees(
        uint256 fee,
        uint256 protocolBps,
        uint256 sellOnBps,
        uint256 sellerAgentBps,
        uint256 buyerAgentBps
    )
        external
        pure
        returns (
            uint256 protocolAmt,
            uint256 sellOnAmt,
            uint256 sellerAgentAmt,
            uint256 buyerAgentAmt,
            uint256 sellerAmt
        )
    {
        // I guard against fees summing to over 100% — would cause underflow on remaining
        if (protocolBps + sellOnBps + sellerAgentBps + buyerAgentBps > 10_000)
            revert FeesExceed100Pct();

        // I compute each percentage from gross fee — no compounding
        uint256 remaining = fee;
        protocolAmt    = (fee * protocolBps)    / 10_000; remaining -= protocolAmt;
        sellOnAmt      = (fee * sellOnBps)      / 10_000; remaining -= sellOnAmt;
        sellerAgentAmt = (fee * sellerAgentBps) / 10_000; remaining -= sellerAgentAmt;
        buyerAgentAmt  = (fee * buyerAgentBps)  / 10_000; remaining -= buyerAgentAmt;
        sellerAmt      = remaining;
    }
}
