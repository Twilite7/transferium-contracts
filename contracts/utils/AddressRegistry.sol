// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title AddressRegistry
 * @notice Central registry for peripheral protocol addresses.
 *         Core references (PlayerRegistry) are immutable in escrow constructors.
 *         All updates here go through a 48h timelock.
 */
contract AddressRegistry is AccessControl {
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    uint256 public constant TIMELOCK_DELAY = 48 hours;

    struct PendingUpdate {
        address newAddress;
        uint256 executableAt;
        bool    exists;
    }

    mapping(bytes32 => address)        private _addresses;
    mapping(bytes32 => PendingUpdate)  private _pending;

    event UpdateProposed(bytes32 indexed key, address indexed newAddress, uint256 executableAt);
    event UpdateExecuted(bytes32 indexed key, address indexed oldAddress, address indexed newAddress);
    event UpdateCancelled(bytes32 indexed key);

    error TooEarly(uint256 executableAt, uint256 currentTime);
    error NoPendingUpdate(bytes32 key);
    error ZeroAddress();

    constructor(address governor) {
        _grantRole(DEFAULT_ADMIN_ROLE, governor);
        _grantRole(GOVERNOR_ROLE, governor);
    }

    function get(bytes32 key) external view returns (address) {
        return _addresses[key];
    }

    function getPending(bytes32 key) external view returns (PendingUpdate memory) {
        return _pending[key];
    }

    function propose(bytes32 key, address newAddress) external onlyRole(GOVERNOR_ROLE) {
        if (newAddress == address(0)) revert ZeroAddress();
        uint256 executableAt = block.timestamp + TIMELOCK_DELAY;
        _pending[key] = PendingUpdate({ newAddress: newAddress, executableAt: executableAt, exists: true });
        emit UpdateProposed(key, newAddress, executableAt);
    }

    function execute(bytes32 key) external onlyRole(GOVERNOR_ROLE) {
        PendingUpdate memory p = _pending[key];
        if (!p.exists) revert NoPendingUpdate(key);
        if (block.timestamp < p.executableAt) revert TooEarly(p.executableAt, block.timestamp);
        address old = _addresses[key];
        _addresses[key] = p.newAddress;
        delete _pending[key];
        emit UpdateExecuted(key, old, p.newAddress);
    }

    function cancel(bytes32 key) external onlyRole(GOVERNOR_ROLE) {
        if (!_pending[key].exists) revert NoPendingUpdate(key);
        delete _pending[key];
        emit UpdateCancelled(key);
    }

    function seed(bytes32 key, address addr) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_addresses[key] == address(0), "Already set: use propose/execute");
        if (addr == address(0)) revert ZeroAddress();
        _addresses[key] = addr;
        emit UpdateExecuted(key, address(0), addr);
    }
}
