// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title TransferWindow
 * @author Transferium Protocol
 * @notice Manages transfer window periods. Only allows deal creation during open windows.
 *         Mirrors real-world football transfer windows: January and summer.
 * @dev Security-first: admin-controlled window schedules, no automatic state transitions.
 *      External contracts call isWindowOpen() before allowing deal creation.
 */
contract TransferWindow is AccessControl, Pausable {

    // ─── Roles ────────────────────────────────────────────────────────────────
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // ─── Constants ────────────────────────────────────────────────────────────
    // I cap how far in the future a window can be scheduled — prevents griefing
    uint256 public constant MAX_SCHEDULE_AHEAD = 365 days;
    // I cap window duration — no window should last more than 90 days
    uint256 public constant MAX_WINDOW_DURATION = 90 days;
    // I require a minimum gap between windows to prevent overlaps
    uint256 public constant MIN_WINDOW_GAP = 1 days;

    // ─── Structs ──────────────────────────────────────────────────────────────
    struct Window {
        uint256 id;
        string  label;       // e.g. "Summer 2025", "January 2026"
        uint256 opensAt;     // Unix timestamp
        uint256 closesAt;    // Unix timestamp
        bool    exists;
    }

    // ─── State ────────────────────────────────────────────────────────────────
    uint256 private _windowIdCounter;

    // windowId => Window
    mapping(uint256 => Window) private _windows;

    // I maintain an ordered list of window IDs for iteration
    uint256[] private _windowIds;

    // ─── Events ───────────────────────────────────────────────────────────────
    event WindowScheduled(uint256 indexed windowId, string label, uint256 opensAt, uint256 closesAt);
    event WindowCancelled(uint256 indexed windowId);
    event WindowExtended(uint256 indexed windowId, uint256 newClosesAt);

    // ─── Errors ───────────────────────────────────────────────────────────────
    error WindowNotFound();
    error WindowAlreadyClosed();
    error WindowNotOpen();
    error WindowOverlap();
    error InvalidWindowTimes();
    error InvalidString();
    error ScheduleTooFarAhead();
    error WindowTooLong();
    error ExtensionTooLong();
    error ExtensionBeforeClose();

    // ─── Constructor ──────────────────────────────────────────────────────────
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    // ─── Admin Functions ──────────────────────────────────────────────────────

    /**
     * @notice Schedule a new transfer window.
     * @dev I validate no overlap with existing future windows.
     *      opensAt must be in the future; closesAt must be after opensAt.
     */
    function scheduleWindow(
        string calldata label,
        uint256 opensAt,
        uint256 closesAt
    )
        external
        onlyRole(ADMIN_ROLE)
        returns (uint256 windowId)
    {
        if (bytes(label).length == 0 || bytes(label).length > 64) revert InvalidString();
        if (opensAt <= block.timestamp) revert InvalidWindowTimes();
        if (closesAt <= opensAt) revert InvalidWindowTimes();
        if (opensAt > block.timestamp + MAX_SCHEDULE_AHEAD) revert ScheduleTooFarAhead();
        if (closesAt - opensAt > MAX_WINDOW_DURATION) revert WindowTooLong();

        // I check for overlaps with all existing future windows
        uint256 len = _windowIds.length;
        for (uint256 i = 0; i < len; i++) {
            Window storage w = _windows[_windowIds[i]];
            if (!w.exists) continue;
            if (w.closesAt <= block.timestamp) continue; // I skip already closed windows

            // I check if the new window overlaps with any open or future window
            bool overlaps = opensAt < w.closesAt + MIN_WINDOW_GAP &&
                            closesAt + MIN_WINDOW_GAP > w.opensAt;
            if (overlaps) revert WindowOverlap();
        }

        _windowIdCounter++;
        windowId = _windowIdCounter;

        _windows[windowId] = Window({
            id:       windowId,
            label:    label,
            opensAt:  opensAt,
            closesAt: closesAt,
            exists:   true
        });

        _windowIds.push(windowId);

        emit WindowScheduled(windowId, label, opensAt, closesAt);
    }

    /**
     * @notice Cancel a future window that has not yet opened.
     * @dev I do not allow cancelling a window that is already open or closed —
     *      deals may have been created in good faith during an open window.
     */
    function cancelWindow(uint256 windowId) external onlyRole(ADMIN_ROLE) {
        Window storage w = _windows[windowId];
        if (!w.exists) revert WindowNotFound();
        if (w.opensAt <= block.timestamp) revert WindowAlreadyClosed(); // open or past

        w.exists = false;

        emit WindowCancelled(windowId);
    }

    /**
     * @notice Extend the closing time of a currently open window.
     * @dev I only allow extending an open window, not a future or closed one.
     *      Extension cannot exceed MAX_WINDOW_DURATION from original open time.
     */
    function extendWindow(uint256 windowId, uint256 newClosesAt)
        external
        onlyRole(ADMIN_ROLE)
    {
        Window storage w = _windows[windowId];
        if (!w.exists) revert WindowNotFound();
        if (block.timestamp < w.opensAt) revert WindowNotOpen();   // not open yet
        if (block.timestamp >= w.closesAt) revert WindowAlreadyClosed();
        if (newClosesAt <= w.closesAt) revert ExtensionBeforeClose();
        if (newClosesAt - w.opensAt > MAX_WINDOW_DURATION) revert ExtensionTooLong();

        w.closesAt = newClosesAt;

        emit WindowExtended(windowId, newClosesAt);
    }

    function pause() external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    // ─── Views ────────────────────────────────────────────────────────────────

    /**
     * @notice Returns true if any scheduled window is currently open.
     * @dev This is the primary function called by TransferEscrow before deal creation.
     */
    function isWindowOpen() external view returns (bool) {
        uint256 len = _windowIds.length;
        for (uint256 i = 0; i < len; i++) {
            Window storage w = _windows[_windowIds[i]];
            if (!w.exists) continue;
            if (block.timestamp >= w.opensAt && block.timestamp < w.closesAt) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Returns the currently active window, if any.
     */
    function getActiveWindow() external view returns (Window memory) {
        uint256 len = _windowIds.length;
        for (uint256 i = 0; i < len; i++) {
            Window storage w = _windows[_windowIds[i]];
            if (!w.exists) continue;
            if (block.timestamp >= w.opensAt && block.timestamp < w.closesAt) {
                return w;
            }
        }
        revert WindowNotOpen();
    }

    function getWindow(uint256 windowId) external view returns (Window memory) {
        if (!_windows[windowId].exists) revert WindowNotFound();
        return _windows[windowId];
    }

    function getAllWindowIds() external view returns (uint256[] memory) {
        return _windowIds;
    }

    function totalWindows() external view returns (uint256) {
        return _windowIdCounter;
    }
}
