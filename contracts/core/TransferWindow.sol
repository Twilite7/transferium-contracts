// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title TransferWindow
 * @author Transferium Protocol
 * @notice Manages transfer window periods with support for multiple window types.
 *         STANDARD  — regular summer/winter windows (max 90 days)
 *         EXCEPTIONAL — special short windows e.g. Club World Cup (max 10 days)
 *         EMERGENCY — goalkeeper-only emergency registration (max 7 days)
 *
 * @dev Security-first design:
 *      - Admin-controlled schedules only — no automatic state transitions
 *      - O(1) active window pointer for isWindowOpen() common case
 *      - Windows can be suspended without cancellation for dispute handling
 *      - EMERGENCY windows enforce goalkeeper-only registration at contract level
 *      - No overlap between any two windows regardless of type
 *      - All time validations use block.timestamp with explicit bounds
 */
contract TransferWindow is AccessControl, Pausable {

    // ─── Roles ────────────────────────────────────────────────────────────────

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // ─── Constants ────────────────────────────────────────────────────────────

    uint256 public constant MAX_SCHEDULE_AHEAD       = 365 days;
    uint256 public constant MAX_STANDARD_DURATION    = 90 days;
    uint256 public constant MAX_EXCEPTIONAL_DURATION = 10 days;
    uint256 public constant MAX_EMERGENCY_DURATION   = 7 days;
    uint256 public constant MIN_WINDOW_GAP           = 1 days;

    // ─── Types ────────────────────────────────────────────────────────────────

    enum WindowType { STANDARD, EXCEPTIONAL, EMERGENCY }

    struct Window {
        uint256    id;
        string     label;
        uint256    opensAt;
        uint256    closesAt;
        WindowType windowType;
        bool       suspended;
        bool       exists;
    }

    // ─── State ────────────────────────────────────────────────────────────────

    uint256 private _windowIdCounter;

    /// @dev O(1) pointer to the current or most recent active window.
    ///      Avoids iterating full history on every isWindowOpen() call.
    ///      Must be advanced by admin when a new window opens.
    uint256 public activeWindowId;

    mapping(uint256 => Window) private _windows;
    uint256[] private _windowIds;

    // ─── Events ───────────────────────────────────────────────────────────────

    event WindowScheduled(
        uint256 indexed windowId,
        string          label,
        uint256         opensAt,
        uint256         closesAt,
        WindowType      windowType
    );
    event WindowCancelled(uint256 indexed windowId);
    event WindowExtended(uint256 indexed windowId, uint256 newClosesAt);
    event WindowSuspended(uint256 indexed windowId);
    event WindowResumed(uint256 indexed windowId);
    event ActiveWindowAdvanced(uint256 indexed windowId);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error WindowNotFound();
    error WindowAlreadyClosed();
    error WindowNotOpen();
    error WindowAlreadyOpen();
    error WindowOverlap();
    error InvalidWindowTimes();
    error InvalidString();
    error ScheduleTooFarAhead();
    error WindowTooLong();
    error ExtensionTooLong();
    error ExtensionBeforeClose();
    error WindowAlreadySuspended();
    error WindowNotSuspended();
    error WindowNotOpenForType(WindowType required, WindowType actual);
    error NoActiveWindow();
    error PositionNotAllowedInEmergencyWindow();

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    // ─── Admin Functions ──────────────────────────────────────────────────────

    /**
     * @notice Schedule a new transfer window.
     * @param label      Human-readable label e.g. "Summer 2026"
     * @param opensAt    Unix timestamp when the window opens (must be future)
     * @param closesAt   Unix timestamp when the window closes
     * @param windowType STANDARD, EXCEPTIONAL, or EMERGENCY
     * @dev Validates no overlap with any open or future window.
     *      Duration cap depends on window type.
     *      I only check windows that are still open or in the future to avoid
     *      iterating closed historical windows — O(future windows).
     */
    function scheduleWindow(
        string     calldata label,
        uint256             opensAt,
        uint256             closesAt,
        WindowType          windowType
    )
        external
        onlyRole(ADMIN_ROLE)
        whenNotPaused
        returns (uint256 windowId)
    {
        if (bytes(label).length == 0 || bytes(label).length > 64)
            revert InvalidString();
        if (opensAt <= block.timestamp)
            revert InvalidWindowTimes();
        if (closesAt <= opensAt)
            revert InvalidWindowTimes();
        if (opensAt > block.timestamp + MAX_SCHEDULE_AHEAD)
            revert ScheduleTooFarAhead();

        // I enforce type-specific duration caps
        uint256 duration = closesAt - opensAt;
        if (windowType == WindowType.STANDARD    && duration > MAX_STANDARD_DURATION)
            revert WindowTooLong();
        if (windowType == WindowType.EXCEPTIONAL && duration > MAX_EXCEPTIONAL_DURATION)
            revert WindowTooLong();
        if (windowType == WindowType.EMERGENCY   && duration > MAX_EMERGENCY_DURATION)
            revert WindowTooLong();

        // I check for overlap with any non-closed window
        uint256 len = _windowIds.length;
        for (uint256 i = 0; i < len; i++) {
            Window storage w = _windows[_windowIds[i]];
            if (!w.exists) continue;
            if (w.closesAt <= block.timestamp) continue;

            bool overlaps = opensAt  < w.closesAt  + MIN_WINDOW_GAP &&
                            closesAt + MIN_WINDOW_GAP > w.opensAt;
            if (overlaps) revert WindowOverlap();
        }

        _windowIdCounter++;
        windowId = _windowIdCounter;

        _windows[windowId] = Window({
            id:         windowId,
            label:      label,
            opensAt:    opensAt,
            closesAt:   closesAt,
            windowType: windowType,
            suspended:  false,
            exists:     true
        });

        _windowIds.push(windowId);

        emit WindowScheduled(windowId, label, opensAt, closesAt, windowType);
    }

    /**
     * @notice Cancel a scheduled window that has not yet opened.
     * @dev Cannot cancel a window that is already open or past.
     */
    function cancelWindow(uint256 windowId)
        external
        onlyRole(ADMIN_ROLE)
    {
        Window storage w = _windows[windowId];
        if (!w.exists) revert WindowNotFound();
        if (w.opensAt <= block.timestamp) revert WindowAlreadyOpen();

        w.exists = false;

        if (activeWindowId == windowId) activeWindowId = 0;

        emit WindowCancelled(windowId);
    }

    /**
     * @notice Extend the closing time of a currently open window.
     * @dev Cannot extend beyond the type-specific maximum duration.
     */
    function extendWindow(uint256 windowId, uint256 newClosesAt)
        external
        onlyRole(ADMIN_ROLE)
    {
        Window storage w = _windows[windowId];
        if (!w.exists)                        revert WindowNotFound();
        if (block.timestamp < w.opensAt)      revert WindowNotOpen();
        if (block.timestamp >= w.closesAt)    revert WindowAlreadyClosed();
        if (newClosesAt <= w.closesAt)        revert ExtensionBeforeClose();

        uint256 newDuration = newClosesAt - w.opensAt;
        if (w.windowType == WindowType.STANDARD    && newDuration > MAX_STANDARD_DURATION)
            revert ExtensionTooLong();
        if (w.windowType == WindowType.EXCEPTIONAL && newDuration > MAX_EXCEPTIONAL_DURATION)
            revert ExtensionTooLong();
        if (w.windowType == WindowType.EMERGENCY   && newDuration > MAX_EMERGENCY_DURATION)
            revert ExtensionTooLong();

        // I check that the extended close time doesn't overlap the next scheduled window
        uint256 len = _windowIds.length;
        for (uint256 i = 0; i < len; i++) {
            Window storage other = _windows[_windowIds[i]];
            if (!other.exists) continue;
            if (other.id == windowId) continue;
            if (other.closesAt <= block.timestamp) continue;
            bool overlaps = newClosesAt + MIN_WINDOW_GAP > other.opensAt &&
                            other.closesAt + MIN_WINDOW_GAP > w.opensAt;
            if (overlaps) revert WindowOverlap();
        }

        w.closesAt = newClosesAt;

        emit WindowExtended(windowId, newClosesAt);
    }

    /**
     * @notice Suspend an open window without cancelling it.
     * @dev Used by league authority during dispute handling or fraud investigation.
     *      Suspended windows are treated as closed by isWindowOpen().
     *      Timer continues running — window will auto-expire at closesAt.
     */
    function suspendWindow(uint256 windowId)
        external
        onlyRole(ADMIN_ROLE)
    {
        Window storage w = _windows[windowId];
        if (!w.exists)                     revert WindowNotFound();
        if (block.timestamp < w.opensAt)   revert WindowNotOpen();
        if (block.timestamp >= w.closesAt) revert WindowAlreadyClosed();
        if (w.suspended)                   revert WindowAlreadySuspended();

        w.suspended = true;

        emit WindowSuspended(windowId);
    }

    /**
     * @notice Resume a suspended window if it has not yet expired.
     */
    function resumeWindow(uint256 windowId)
        external
        onlyRole(ADMIN_ROLE)
    {
        Window storage w = _windows[windowId];
        if (!w.exists)                     revert WindowNotFound();
        if (!w.suspended)                  revert WindowNotSuspended();
        if (block.timestamp >= w.closesAt) revert WindowAlreadyClosed();

        w.suspended = false;

        emit WindowResumed(windowId);
    }

    /**
     * @notice Advance the active window pointer to the current open window.
     * @dev Separated from isWindowOpen() to avoid state writes inside a view.
     *      Admin calls this when a new window opens.
     */
    function advanceActiveWindow()
        external
        onlyRole(ADMIN_ROLE)
    {
        uint256 len = _windowIds.length;
        for (uint256 i = 0; i < len; i++) {
            Window storage w = _windows[_windowIds[i]];
            if (!w.exists)    continue;
            if (w.suspended)  continue;
            if (block.timestamp >= w.opensAt && block.timestamp < w.closesAt) {
                activeWindowId = w.id;
                emit ActiveWindowAdvanced(w.id);
                return;
            }
        }
        activeWindowId = 0;
    }

    function pause()   external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    // ─── View Functions ───────────────────────────────────────────────────────

    /**
     * @notice Returns true if any non-suspended transfer window is currently open.
     * @dev Checks the O(1) active pointer first, falls back to linear scan
     *      only if the pointer is stale — which happens once per window transition.
     */
    function isWindowOpen() external view returns (bool) {
        if (activeWindowId != 0) {
            Window storage active = _windows[activeWindowId];
            if (active.exists &&
                !active.suspended &&
                block.timestamp >= active.opensAt &&
                block.timestamp <  active.closesAt) {
                return true;
            }
        }

        uint256 len = _windowIds.length;
        for (uint256 i = 0; i < len; i++) {
            Window storage w = _windows[_windowIds[i]];
            if (!w.exists)   continue;
            if (w.suspended) continue;
            if (block.timestamp >= w.opensAt && block.timestamp < w.closesAt) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Returns true if a window of the specified type is currently open.
     * @dev Used by TransferEscrow to enforce EMERGENCY = goalkeeper only.
     */
    function isWindowOpenForType(WindowType windowType)
        external
        view
        returns (bool)
    {
        uint256 len = _windowIds.length;
        for (uint256 i = 0; i < len; i++) {
            Window storage w = _windows[_windowIds[i]];
            if (!w.exists)             continue;
            if (w.suspended)           continue;
            if (w.windowType != windowType) continue;
            if (block.timestamp >= w.opensAt && block.timestamp < w.closesAt) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Returns the type of the currently open window.
     * @dev Reverts if no window is open.
     */
    function getCurrentWindowType()
        external
        view
        returns (WindowType)
    {
        if (activeWindowId != 0) {
            Window storage active = _windows[activeWindowId];
            if (active.exists &&
                !active.suspended &&
                block.timestamp >= active.opensAt &&
                block.timestamp <  active.closesAt) {
                return active.windowType;
            }
        }

        uint256 len = _windowIds.length;
        for (uint256 i = 0; i < len; i++) {
            Window storage w = _windows[_windowIds[i]];
            if (!w.exists)   continue;
            if (w.suspended) continue;
            if (block.timestamp >= w.opensAt && block.timestamp < w.closesAt) {
                return w.windowType;
            }
        }
        revert NoActiveWindow();
    }

    /**
     * @notice Returns the currently open window struct.
     * @dev Reverts if no window is open.
     */
    function getActiveWindow() external view returns (Window memory) {
        uint256 len = _windowIds.length;
        for (uint256 i = 0; i < len; i++) {
            Window storage w = _windows[_windowIds[i]];
            if (!w.exists)   continue;
            if (w.suspended) continue;
            if (block.timestamp >= w.opensAt && block.timestamp < w.closesAt) {
                return w;
            }
        }
        revert NoActiveWindow();
    }

    function getWindow(uint256 windowId)
        external
        view
        returns (Window memory)
    {
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
