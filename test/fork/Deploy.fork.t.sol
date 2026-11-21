// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SlipGuardVault} from "../../src/SlipGuardVault.sol";
import {SlipGuardVaultFactory} from "../../src/SlipGuardVaultFactory.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {DeployConfig} from "../../script/DeployConfig.sol";

abstract contract DeployForkBase is Test {
    bool active;

    function _rpcEnv() internal pure virtual returns (string memory);
    function _chainId() internal pure virtual returns (uint256);

    function setUp() public {
        if (block.chainid == _chainId()) {
            // already on this chain's fork
        } else if (block.chainid == 31337) {
            string memory rpc = vm.envOr(_rpcEnv(), string(""));
            if (bytes(rpc).length == 0) return;
            vm.createSelectFork(rpc);
        } else {
            return;
        }
        active = true;
        assertEq(block.chainid, _chainId(), "wrong fork chain");
    }

    modifier onFork() {
        if (!active) {
            vm.skip(true);
            return;
        }
        _;
    }

    function test_fork_deployScript_factoryAndCanonicalTokens() public onFork {
        Deploy script = new Deploy();
        (SlipGuardVaultFactory factory, address usdc, address weth) = script.run();

        assertTrue(address(factory).code.length > 0, "factory not deployed");
        assertEq(usdc, DeployConfig.get(block.chainid).usdc, "must use canonical USDC");
        assertEq(weth, DeployConfig.get(block.chainid).weth, "must use canonical WETH");
        assertEq(factory.weth(), weth);
        assertEq(IERC20Metadata(usdc).symbol(), "USDC");
        assertEq(IERC20Metadata(usdc).decimals(), 6);

        address user = makeAddr("vault-owner");
        vm.prank(user);
        address vault = factory.createVault();
        assertTrue(vault.code.length > 0, "vault not created");
        assertEq(SlipGuardVault(payable(vault)).owner(), user);
        assertEq(SlipGuardVault(payable(vault)).weth(), weth);
        address[] memory list = factory.vaultsOf(user);
        assertEq(list.length, 1);
        assertEq(list[0], vault);
    }

    function test_fork_deployScript_confirmMainnetNotSetIsDryRunSafe() public onFork {
        vm.setEnv("CONFIRM_MAINNET", "");
        Deploy script = new Deploy();
        (SlipGuardVaultFactory factory,,) = script.run();
        assertTrue(address(factory).code.length > 0);
    }
}

contract EthereumDeployForkTest is DeployForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "MAINNET_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 1;
    }
}

contract BaseDeployForkTest is DeployForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "BASE_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 8453;
    }
}
