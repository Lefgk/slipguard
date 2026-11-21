// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {DeployConfig} from "../script/DeployConfig.sol";
import {Addresses} from "../src/Addresses.sol";
import {SlipGuardVaultFactory} from "../src/SlipGuardVaultFactory.sol";
import {SlipGuardVault} from "../src/SlipGuardVault.sol";

contract DeployConfigTest is Test {
    function test_ethereumAndBaseAddressesAndFlags() public pure {
        DeployConfig.Chain memory e = DeployConfig.get(1);
        assertEq(e.usdc, 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        assertEq(e.weth, 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        assertTrue(e.isMainnet);
        DeployConfig.Chain memory b = DeployConfig.get(8453);
        assertEq(b.usdc, 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
        assertEq(b.weth, 0x4200000000000000000000000000000000000006);
        assertTrue(b.isMainnet);
        assertEq(Addresses.SWAP_ROUTER02_ETHEREUM, 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45);
        assertEq(Addresses.SWAP_ROUTER02_BASE, 0x2626664c2603336E57B271c5C0b26F421741e481);
        assertEq(Addresses.UR_ETHEREUM, 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af);
        assertEq(Addresses.UR_BASE, 0x6fF5693b99212Da76ad316178A184AB56D299b43);
        assertEq(Addresses.INCH_V6, 0x111111125421cA6dc452d289314280a0f8842A65);
    }

    function test_anvilConfigIsNotMainnet() public pure {
        DeployConfig.Chain memory c = DeployConfig.get(31337);
        assertEq(c.usdc, address(0));
        assertEq(c.weth, address(0));
        assertFalse(c.isMainnet);
    }

    function test_unsupportedChainReverts() public {
        vm.chainId(11155111);
        Deploy script = new Deploy();
        vm.expectRevert(bytes("Addresses: unsupported chain (only 1, 8453, 31337)"));
        script.run();
    }

    function test_deployScriptOnAnvilDeploysFactoryMockUsdcAndWeth() public {
        if (block.chainid != 31337) {
            vm.skip(true);
            return;
        }
        Deploy script = new Deploy();
        (SlipGuardVaultFactory factory, address usdc, address weth) = script.run();
        assertTrue(address(factory).code.length > 0);
        assertTrue(usdc.code.length > 0);
        assertTrue(weth.code.length > 0);
        assertEq(factory.weth(), weth);
        assertEq(factory.vaultsOf(address(this)).length, 0);
        address vault = factory.createVault();
        assertTrue(vault.code.length > 0);
        assertEq(SlipGuardVault(payable(vault)).owner(), address(this));
        assertEq(SlipGuardVault(payable(vault)).weth(), weth);
        assertEq(factory.vaultsOf(address(this)).length, 1);
    }
}
