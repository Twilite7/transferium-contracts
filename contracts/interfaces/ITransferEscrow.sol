// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ITransferEscrow
 * @notice Minimal interface used by ReleaseEscrow to check player activity
 *         in the main transfer contract before triggering a release clause.
 */
interface ITransferEscrow {
    // I only expose the two checks ReleaseEscrow actually needs
    function getPlayerOffer(uint256 playerId) external view returns (uint256);
    function getPlayerDeal(uint256 playerId)  external view returns (uint256);
}
