// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Addresses} from "../src/Addresses.sol";

/// @notice Per-chain deploy settings. Only Ethereum, Base and local anvil are supported.
library DeployConfig {
    struct Chain {
        string name;
        bool isMainnet;
        address usdc;
        address weth;
    }

    function get(uint256 chainId) internal pure returns (Chain memory) {
        Addresses.Chain memory c = Addresses.get(chainId);
        return Chain(c.name, c.isMainnet, c.usdc, c.weth);
    }
}
