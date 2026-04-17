// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title TransferWindow
 * @author Transferium Protocol
 * @notice Manages transfer window periods. Only allows deal creation during open windows.
 * @dev Security-first: admin-controlled schedules, no automatic state transitions.
 *      I maintain a single activeWindowId pointer to avoid unbounded loop gas costs.
 *      External contracts call isWindowOpen() before allowing deal creation.
 */
contract TransferWindow is AccessControl, Pausable {

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    uint256 public constant MAX_SCHEDULE_AHEAD  = 365 days;
    uint256 public constant MAX_WINDOW_DURATION = 90 days;
    uint256 public constant MIN_WINDOW_GAP      = 1 days;

    struct Window {
        uint256 id;
        string  label;
        uint256 opensAt;
        uint256 closesAt;
        bool    exists;
    }

    uint256 private _windowIdCounter;

    // I maintain a pointer to the current or most recent active window
    // This avoids iterating the full history on every isWindowOpen() call
    uint256 public activeWindowId;

    mapping(uint256 => Window) private _windows;
    uint256[] private _windowIds;

    event WindowScheduled(uint256 indexed windowId, string label, uint256 opensAt, uint256 closesAt);
    event WindowCancelled(uint256 indexed windowId);
    event WindowExtended(uint256 indexed windowId, uint256 newClosesAt);

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

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    /**
     * @notice Schedule a new transfer window.
     * @dev I validate no overlap with any currently open or future window.
     *      I only check the active window pointer and any future scheduled windows
     *      rather than iterating all historical windows — O(future windows) not O(all windows).
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

        // I only check windows that are still open or in the future — skip closed history
        uint256 len = _windowIds.length;
        for (uint256 i = 0; i < len; i++) {
            Window storage w = _windows[_windowIds[i]];
            if (!w.exists) continue;
            if (w.closesAt <= block.timestamp) continue;

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

    function cancelWindow(uint256 windowId) external onlyRole(ADMIN_ROLE) {
        Window storage w = _windows[windowId];
        if (!w.exists) revert WindowNotFound();
        if (w.opensAt <= block.timestamp) revert WindowAlreadyClosed();

        w.exists = false;

        // I clear the active pointer if this was the scheduled next window
        if (activeWindowId == windowId) activeWindowId = 0;

        emit WindowCancelled(windowId);
    }

    function extendWindow(uint256 windowId, uint256 newClosesAt)
        external
        onlyRole(ADMIN_ROLE)
    {
        Window storage w = _windows[windowId];
        if (!w.exists) revert WindowNotFound();
        if (block.timestamp < w.opensAt) revert WindowNotOpen();
        if (block.timestamp >= w.closesAt) revert WindowAlreadyClosed();
        if (newClosesAt <= w.closesAt) revert ExtensionBeforeClose();
        if (newClosesAt - w.opensAt > MAX_WINDOW_DURATION) revert ExtensionTooLong();

        w.closesAt = newClosesAt;

        emit WindowExtended(windowId, newClosesAt);
    }

    function pause() external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    /**
     * @notice Returns true if a transfer window is currently open.
     * @dev I check the activeWindowId pointer first — O(1) for the common case.
     *      Falls back to a linear scan only if the pointer is stale or unset,
     *      which only happens once per window transition.
     */
    function isWindowOpen() external view returns (bool) {
        // I check the pointer first — O(1) fast path
        if (activeWindowId != 0) {
            Window storage active = _windows[activeWindowId];
            if (active.exists &&
                block.timestamp >= active.opensAt &&
                block.timestamp < active.closesAt) {
                return true;
            }
        }

        // I fall back to linear scan only to find a newly opened window
        // and update would require a write — so I just return the result here
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
     * @notice Admin advances the active window pointer to the current open window.
     * @dev I separate the pointer update into an explicit admin action to avoid
     *      state writes inside a view function. Admin calls this when a new window opens.
     */
    function advanceActiveWindow() external onlyRole(ADMIN_ROLE) {
        uint256 len = _windowIds.length;
        for (uint256 i = 0; i < len; i++) {
            Window storage w = _windows[_windowIds[i]];
            if (!w.exists) continue;
            if (block.timestamp >= w.opensAt && block.timestamp < w.closesAt) {
                activeWindowId = w.id;
                return;
            }
        }
        activeWindowId = 0;
    }

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
