// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library RegistryKeys {
    bytes32 constant TRANSFER_WINDOW     = keccak256("TRANSFER_WINDOW");
    bytes32 constant INSTALLMENT_ESCROW  = keccak256("INSTALLMENT_ESCROW");
    bytes32 constant FEE_RECIPIENT       = keccak256("FEE_RECIPIENT");
    bytes32 constant EURC_TOKEN          = keccak256("EURC_TOKEN");
    bytes32 constant USDC_TOKEN          = keccak256("USDC_TOKEN");
}
