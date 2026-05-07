// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ITransferWindow
 * @author Transferium Protocol
 * @notice Interface for TransferWindow — used by TransferEscrow.
 */
interface ITransferWindow {
    enum WindowType { STANDARD, EXCEPTIONAL, EMERGENCY }

    function isWindowOpen() external view returns (bool);
    function isWindowOpenForType(WindowType windowType) external view returns (bool);
    function getCurrentWindowType() external view returns (WindowType);
}
