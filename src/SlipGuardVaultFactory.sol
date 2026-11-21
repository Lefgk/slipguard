// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SlipGuardVault} from "./SlipGuardVault.sol";

/// @title SlipGuardVaultFactory
/// @notice Deploys one SlipGuardVault per call, owned by the caller, and indexes vaults by owner.
contract SlipGuardVaultFactory {
    address public immutable weth;
    mapping(address owner => address[]) internal _vaultsOf;

    event VaultCreated(address indexed owner, address indexed vault);

    constructor(address weth_) {
        require(weth_ != address(0), "factory: zero weth");
        weth = weth_;
    }

    function createVault() external returns (address vault) {
        vault = address(new SlipGuardVault(msg.sender, weth));
        _vaultsOf[msg.sender].push(vault);
        emit VaultCreated(msg.sender, vault);
    }

    function vaultsOf(address owner) external view returns (address[] memory) {
        return _vaultsOf[owner];
    }
}
