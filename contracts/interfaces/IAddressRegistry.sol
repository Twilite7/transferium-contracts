// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IAddressRegistry {
    function get(bytes32 key) external view returns (address);
}
