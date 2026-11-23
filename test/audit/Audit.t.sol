// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SlipGuardVault} from "../../src/SlipGuardVault.sol";
import {MockUSDC} from "../../src/MockUSDC.sol";
import {MockWETH} from "../../src/MockWETH.sol";
import {MockAggregator} from "../../src/mocks/MockAggregator.sol";
import {MockRouter} from "../../src/mocks/MockRouter.sol";

contract MockSequencerFeed {
    int256 public answer;
    uint256 public startedAt;

    function set(int256 a, uint256 s) external {
        answer = a;
        startedAt = s;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, startedAt, startedAt, 1);
    }
}

/// @dev Router that tries to re-enter the vault during the swap call.
contract ReentrantRouter {
    function reenterSwap(SlipGuardVault v, address tIn, address tOut) external {
        v.executeSwap(tIn, tOut, 1, address(this), "");
    }

    function reenterWrap(SlipGuardVault v) external {
        v.wrapETH();
    }
}

/// @dev Audit 2026-11-23 regression and refutation tests (AUDIT-2026-11-23.md).
contract SlipGuardAuditTest is Test {
    SlipGuardVault vault;
    MockUSDC usdc;
    MockWETH weth;
    MockAggregator ethUsd;
    MockAggregator usdcUsd;
    MockRouter router;
    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address constant SEQ = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;

    uint16 constant SLIP = 2_000; // worst case the owner can grant: 20%
    uint128 constant MAX_TX = 1_000e8;
    uint128 constant DAILY = 5_000e8;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockUSDC();
        weth = new MockWETH();
        ethUsd = new MockAggregator(3000e8, block.timestamp);
        usdcUsd = new MockAggregator(1e8, block.timestamp);
        router = new MockRouter();
        usdc.mint(address(router), 1_000_000e6);
        vm.deal(address(this), 300 ether);
        weth.deposit{value: 300 ether}();
        weth.transfer(address(router), 100 ether);
        vault = _newVault();
    }

    function _newVault() internal returns (SlipGuardVault v) {
        v = new SlipGuardVault(owner, address(weth));
        usdc.mint(address(v), 100_000e6);
        weth.transfer(address(v), 20 ether);
        vm.startPrank(owner);
        v.setFeed(address(weth), address(ethUsd), 1 hours);
        v.setFeed(address(usdc), address(usdcUsd), 1 days);
        v.grantAgent(agent, uint64(block.timestamp + 7 days), SLIP, MAX_TX, DAILY);
        v.setTokenAllowed(agent, address(usdc), true);
        v.setTokenAllowed(agent, address(weth), true);
        v.setRouterAllowed(agent, address(router), true);
        vm.stopPrank();
    }

    function _worstSwap(SlipGuardVault v, address tIn, address tOut, uint256 amountIn) internal {
        uint256 minOut = v.previewMinOut(tIn, tOut, amountIn, SLIP);
        bytes memory data =
            abi.encodeWithSelector(MockRouter.swap.selector, tIn, tOut, amountIn, minOut, address(v), address(v));
        vm.prank(agent);
        v.executeSwap(tIn, tOut, amountIn, address(router), data);
    }

    function _valueUsd8(SlipGuardVault v) internal view returns (uint256) {
        return v.quoteUsd(address(usdc), usdc.balanceOf(address(v))) + v.quoteUsd(address(weth), weth.balanceOf(address(v)));
    }

    // ------------------------------------------------ M-01: Base sequencer uptime

    function _baseVault(int256 answer, uint256 startedAt) internal returns (SlipGuardVault v) {
        vm.chainId(8453);
        MockSequencerFeed impl = new MockSequencerFeed();
        vm.etch(SEQ, address(impl).code);
        MockSequencerFeed(SEQ).set(answer, startedAt);
        v = _newVault();
        assertEq(v.sequencerFeed(), SEQ);
    }

    function test_M01_noSequencerFeedOffBase() public view {
        assertEq(vault.sequencerFeed(), address(0));
    }

    function test_M01_swapRevertsWhileSequencerDown() public {
        SlipGuardVault v = _baseVault(1, block.timestamp - 10 minutes);
        vm.prank(agent);
        vm.expectRevert(SlipGuardVault.SequencerDown.selector);
        v.executeSwap(address(usdc), address(weth), 100e6, address(router), "");
    }

    function test_M01_swapRevertsInGracePeriodThenWorks() public {
        SlipGuardVault v = _baseVault(0, block.timestamp - 30 minutes);
        vm.prank(agent);
        vm.expectRevert(SlipGuardVault.SequencerGracePeriod.selector);
        v.executeSwap(address(usdc), address(weth), 100e6, address(router), "");
        vm.warp(block.timestamp + 31 minutes);
        ethUsd.set(3000e8, block.timestamp);
        usdcUsd.set(1e8, block.timestamp);
        _worstSwap(v, address(usdc), address(weth), 100e6);
    }

    // ------------------------------------------------ refutations / bounded-loss properties

    /// L-01 (acknowledged, by design): a malicious agent that routes through its own pool at exactly
    /// min-out loses at most maxSlippageBps of the daily cap per 24h window.
    function testFuzz_L01_dailyLossBoundedBySlippageTimesCap(uint256 seed) public {
        uint256 v0 = _valueUsd8(vault);
        uint256 spent;
        for (uint256 i; i < 12; i++) {
            uint256 usd = bound(uint256(keccak256(abi.encode(seed, i))), 1e8, MAX_TX);
            if (spent + usd > DAILY) break;
            if (i % 2 == 0) {
                _worstSwap(vault, address(usdc), address(weth), usd / 100); // usd8 -> 6dp USDC
            } else {
                _worstSwap(vault, address(weth), address(usdc), usd * 1e10 / 3000);
            }
            spent += usd;
        }
        uint256 loss = v0 - _valueUsd8(vault);
        assertLe(loss, uint256(DAILY) * SLIP / 10_000 + 1e8, "loss bounded by slippage x daily cap");
        // the next swap that would exceed the cap reverts
        vm.prank(agent);
        vm.expectRevert();
        vault.executeSwap(address(usdc), address(weth), (DAILY - spent) / 100 + 1e6, address(router), "");
    }

    /// Refuted: the router cannot pull tokenOut or any other vault token; approvals are cleared.
    function test_refute_routerCannotPullOtherTokens() public {
        bytes memory data = abi.encodeWithSelector(MockRouter.overpull.selector, address(weth), address(vault), 1);
        vm.prank(agent);
        vm.expectRevert();
        vault.executeSwap(address(usdc), address(weth), 100e6, address(router), data);
        _worstSwap(vault, address(usdc), address(weth), 100e6);
        assertEq(usdc.allowance(address(vault), address(router)), 0);
        assertEq(weth.allowance(address(vault), address(router)), 0);
    }

    /// Refuted: re-entrancy from an allowlisted router into executeSwap / wrapETH is blocked.
    function test_refute_reentrancyBlocked() public {
        ReentrantRouter rr = new ReentrantRouter();
        vm.prank(owner);
        vault.setRouterAllowed(agent, address(rr), true);
        bytes memory d1 = abi.encodeCall(ReentrantRouter.reenterSwap, (vault, address(usdc), address(weth)));
        vm.prank(agent);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vault.executeSwap(address(usdc), address(weth), 100e6, address(rr), d1);
        vm.deal(address(vault), 1 ether);
        bytes memory d2 = abi.encodeCall(ReentrantRouter.reenterWrap, (vault));
        vm.prank(agent);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vault.executeSwap(address(usdc), address(weth), 100e6, address(rr), d2);
    }
}
