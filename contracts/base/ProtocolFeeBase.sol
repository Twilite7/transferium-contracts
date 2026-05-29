// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title  ProtocolFeeBase
 * @author Transferium Protocol
 * @notice Shared treasury timelock and protocol fee configuration for all
 *         escrow contracts.
 */
abstract contract ProtocolFeeBase {

    uint256 internal constant MAX_PROTOCOL_FEE_BPS  = 2_000;
    uint256 internal constant TREASURY_UPDATE_DELAY = 48 hours;

    address public treasury;
    uint256 public protocolFeeBps;

    address private _pendingTreasury;
    uint256 private _pendingTreasuryEffectiveAt;

    error ProtocolFeeTooHigh();
    error NoPendingTreasuryUpdate();
    error TreasuryUpdateNotReady();

    event ProtocolFeeUpdated(uint256 bps);
    event ProtocolTreasuryUpdateScheduled(address indexed newTreasury, uint256 effectiveAt);
    event ProtocolTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event ProtocolFeesWithdrawn(address indexed treasury, address indexed token, uint256 amount);

    function _setProtocolFee(uint256 bps) internal {
        if (bps > MAX_PROTOCOL_FEE_BPS) revert ProtocolFeeTooHigh();
        protocolFeeBps = bps;
        emit ProtocolFeeUpdated(bps);
    }

    function _scheduleProtocolTreasuryUpdate(address newTreasury) internal {
        _pendingTreasury            = newTreasury;
        _pendingTreasuryEffectiveAt = block.timestamp + TREASURY_UPDATE_DELAY;
        emit ProtocolTreasuryUpdateScheduled(newTreasury, _pendingTreasuryEffectiveAt);
    }

    function _executeProtocolTreasuryUpdate() internal {
        if (_pendingTreasuryEffectiveAt == 0) revert NoPendingTreasuryUpdate();
        if (block.timestamp < _pendingTreasuryEffectiveAt)
            revert TreasuryUpdateNotReady();
        address prev                = treasury;
        treasury                    = _pendingTreasury;
        _pendingTreasury            = address(0);
        _pendingTreasuryEffectiveAt = 0;
        emit ProtocolTreasuryUpdated(prev, treasury);
    }

    function pendingTreasury() external view returns (address, uint256) {
        return (_pendingTreasury, _pendingTreasuryEffectiveAt);
    }
}
