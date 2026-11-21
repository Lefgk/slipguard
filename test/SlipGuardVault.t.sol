// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SlipGuardVault} from "../src/SlipGuardVault.sol";
import {SlipGuardVaultFactory} from "../src/SlipGuardVaultFactory.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockWETH} from "../src/MockWETH.sol";
import {MockAggregator} from "../src/mocks/MockAggregator.sol";
import {MockRouter} from "../src/mocks/MockRouter.sol";

contract SlipGuardVaultTest is Test {
    SlipGuardVault vault;
    MockUSDC usdc;
    MockWETH weth;
    MockAggregator ethUsd;
    MockAggregator usdcUsd;
    MockRouter router;
    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address stranger = makeAddr("stranger");
    address guardian = makeAddr("guardian");

    uint16 constant SLIP = 100; // 1%
    uint128 constant MAX_TX = 1_000e8; // $1,000
    uint128 constant DAILY = 5_000e8; // $5,000
    int256 constant ETH_PRICE = 3000e8;
    int256 constant USDC_PRICE = 1e8;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockUSDC();
        weth = new MockWETH();
        vault = new SlipGuardVault(owner, address(weth));
        ethUsd = new MockAggregator(ETH_PRICE, block.timestamp);
        usdcUsd = new MockAggregator(USDC_PRICE, block.timestamp);
        router = new MockRouter();

        usdc.mint(owner, 1_000_000e6);
        usdc.mint(address(router), 1_000_000e6);
        vm.deal(owner, 200 ether);
        vm.deal(address(this), 200 ether);
        weth.deposit{value: 150 ether}();
        weth.transfer(address(router), 100 ether);
        vm.startPrank(owner);
        weth.deposit{value: 50 ether}();
        usdc.approve(address(vault), type(uint256).max);
        weth.approve(address(vault), type(uint256).max);
        vault.deposit(address(usdc), 100_000e6);
        vault.deposit(address(weth), 20 ether);
        vault.setFeed(address(weth), address(ethUsd), 1 hours);
        vault.setFeed(address(usdc), address(usdcUsd), 1 days);
        _grantDefault();
        vm.stopPrank();
    }

    function _grantDefault() internal {
        vault.grantAgent(agent, uint64(block.timestamp + 7 days), SLIP, MAX_TX, DAILY);
        vault.setTokenAllowed(agent, address(usdc), true);
        vault.setTokenAllowed(agent, address(weth), true);
        vault.setRouterAllowed(agent, address(router), true);
    }

    function _minOut(address tokenIn, address tokenOut, uint256 amountIn, uint16 slip) internal view returns (uint256) {
        return vault.previewMinOut(tokenIn, tokenOut, amountIn, slip);
    }

    function _swapCall(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address recipient)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeWithSelector(
            MockRouter.swap.selector, tokenIn, tokenOut, amountIn, amountOut, address(vault), recipient
        );
    }

    function _agentSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut) internal returns (uint256) {
        bytes memory data = _swapCall(tokenIn, tokenOut, amountIn, amountOut, address(vault));
        vm.prank(agent);
        return vault.executeSwap(tokenIn, tokenOut, amountIn, address(router), data);
    }

    // ------------------------------------------------------------------ factory / deposit

    function test_factoryCreatesOwnerVault() public {
        SlipGuardVaultFactory factory = new SlipGuardVaultFactory(address(weth));
        vm.prank(owner);
        address v = factory.createVault();
        assertEq(SlipGuardVault(payable(v)).owner(), owner);
        assertEq(SlipGuardVault(payable(v)).weth(), address(weth));
        assertEq(factory.vaultsOf(owner).length, 1);
        assertEq(factory.vaultsOf(owner)[0], v);
    }

    function test_depositAndWithdraw() public {
        uint256 beforeOwner = usdc.balanceOf(owner);
        vm.prank(owner);
        vault.withdraw(address(usdc), owner, 1_000e6);
        assertEq(usdc.balanceOf(owner), beforeOwner + 1_000e6);
    }

    function test_wrapAndUnwrapETH() public {
        vm.prank(owner);
        payable(address(vault)).transfer(2 ether);
        uint256 wethBefore = weth.balanceOf(address(vault));
        vault.wrapETH();
        assertEq(weth.balanceOf(address(vault)), wethBefore + 2 ether);
        assertEq(address(vault).balance, 0);
        vm.prank(owner);
        vault.unwrapWETH(1 ether);
        assertEq(address(vault).balance, 1 ether);
        vm.prank(owner);
        vault.withdrawETH(owner, 1 ether);
        assertEq(address(vault).balance, 0);
    }

    function test_strangerCannotWithdraw() public {
        vm.prank(stranger);
        vm.expectRevert();
        vault.withdraw(address(usdc), stranger, 1e6);
    }

    // ------------------------------------------------------------------ happy path + min-out

    function test_swapUsdcToWethWithinSlippage() public {
        uint256 amountIn = 1_000e6; // $1,000, at the per-tx cap
        uint256 minOut = _minOut(address(usdc), address(weth), amountIn, SLIP);
        // pay exactly minOut
        uint256 wethBefore = weth.balanceOf(address(vault));
        uint256 usdcBefore = usdc.balanceOf(address(vault));
        uint256 agentUsdc = usdc.balanceOf(agent);
        uint256 agentWeth = weth.balanceOf(agent);
        uint256 out = _agentSwap(address(usdc), address(weth), amountIn, minOut);
        assertEq(out, minOut);
        assertEq(weth.balanceOf(address(vault)), wethBefore + minOut);
        assertEq(usdc.balanceOf(address(vault)), usdcBefore - amountIn);
        assertEq(usdc.balanceOf(agent), agentUsdc);
        assertEq(weth.balanceOf(agent), agentWeth);
        // approvals cleared
        assertEq(usdc.allowance(address(vault), address(router)), 0);
    }

    function test_swapRevertsWhenOutputBelowMinOut() public {
        uint256 amountIn = 1_000e6;
        uint256 minOut = _minOut(address(usdc), address(weth), amountIn, SLIP);
        bytes memory data = _swapCall(address(usdc), address(weth), amountIn, minOut - 1, address(vault));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(SlipGuardVault.SlippageExceeded.selector, minOut - 1, minOut));
        vault.executeSwap(address(usdc), address(weth), amountIn, address(router), data);
        // no funds moved (full revert)
        assertEq(usdc.balanceOf(agent), 0);
    }

    function test_swapRevertsWhenOutputSentElsewhere() public {
        uint256 amountIn = 1_000e6;
        uint256 minOut = _minOut(address(usdc), address(weth), amountIn, SLIP);
        bytes memory data = _swapCall(address(usdc), address(weth), amountIn, minOut, agent);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(SlipGuardVault.SlippageExceeded.selector, 0, minOut));
        vault.executeSwap(address(usdc), address(weth), amountIn, address(router), data);
        assertEq(weth.balanceOf(agent), 0);
    }

    function test_executeSwapDoesNotPullFromOwnerWallet() public {
        uint256 ownerUsdc = usdc.balanceOf(owner);
        uint256 amountIn = 1_000e6;
        uint256 minOut = _minOut(address(usdc), address(weth), amountIn, SLIP);
        _agentSwap(address(usdc), address(weth), amountIn, minOut);
        assertEq(usdc.balanceOf(owner), ownerUsdc);
    }

    // ------------------------------------------------------------------ policy gates

    function test_unknownAgentReverts() public {
        bytes memory data = _swapCall(address(usdc), address(weth), 1e6, 1, address(vault));
        vm.prank(stranger);
        vm.expectRevert(SlipGuardVault.NotAgent.selector);
        vault.executeSwap(address(usdc), address(weth), 1e6, address(router), data);
    }

    function test_expiredAgentReverts() public {
        vm.warp(block.timestamp + 8 days);
        ethUsd.set(ETH_PRICE, block.timestamp);
        usdcUsd.set(USDC_PRICE, block.timestamp);
        uint256 minOut = _minOut(address(usdc), address(weth), 1e6, SLIP);
        bytes memory data = _swapCall(address(usdc), address(weth), 1e6, minOut, address(vault));
        vm.prank(agent);
        vm.expectRevert(SlipGuardVault.AgentExpired.selector);
        vault.executeSwap(address(usdc), address(weth), 1e6, address(router), data);
    }

    function test_pausedRevertsAndOwnerCanWithdraw() public {
        vm.prank(owner);
        vault.pause();
        uint256 minOut = _minOut(address(usdc), address(weth), 1e6, SLIP);
        bytes memory data = _swapCall(address(usdc), address(weth), 1e6, minOut, address(vault));
        vm.prank(agent);
        vm.expectRevert();
        vault.executeSwap(address(usdc), address(weth), 1e6, address(router), data);
        vm.prank(owner);
        vault.withdraw(address(usdc), owner, 1e6);
        vm.prank(owner);
        vault.unpause();
        _agentSwap(address(usdc), address(weth), 1e6, _minOut(address(usdc), address(weth), 1e6, SLIP));
    }

    function test_tokenAndRouterAllowlists() public {
        vm.prank(owner);
        vault.setTokenAllowed(agent, address(usdc), false);
        uint256 minOut = _minOut(address(usdc), address(weth), 1e6, SLIP);
        bytes memory data = _swapCall(address(usdc), address(weth), 1e6, minOut, address(vault));
        vm.prank(agent);
        vm.expectRevert(SlipGuardVault.TokenNotAllowed.selector);
        vault.executeSwap(address(usdc), address(weth), 1e6, address(router), data);

        vm.startPrank(owner);
        vault.setTokenAllowed(agent, address(usdc), true);
        vault.setRouterAllowed(agent, address(router), false);
        vm.stopPrank();
        vm.prank(agent);
        vm.expectRevert(SlipGuardVault.RouterNotAllowed.selector);
        vault.executeSwap(address(usdc), address(weth), 1e6, address(router), data);
    }

    function test_revokeWipesAllowlistAndCaps() public {
        vm.prank(owner);
        vault.revokeAgent(agent);
        uint256 minOut = _minOut(address(usdc), address(weth), 1e6, SLIP);
        bytes memory data = _swapCall(address(usdc), address(weth), 1e6, minOut, address(vault));
        vm.prank(agent);
        vm.expectRevert(SlipGuardVault.NotAgent.selector);
        vault.executeSwap(address(usdc), address(weth), 1e6, address(router), data);

        // re-grant without restoring allowlists must still fail
        vm.startPrank(owner);
        vault.grantAgent(agent, uint64(block.timestamp + 7 days), SLIP, MAX_TX, DAILY);
        vm.stopPrank();
        vm.prank(agent);
        vm.expectRevert(SlipGuardVault.TokenNotAllowed.selector);
        vault.executeSwap(address(usdc), address(weth), 1e6, address(router), data);
    }

    function test_guardianCanPauseAndRevokeButNotGrant() public {
        vm.prank(owner);
        vault.setGuardian(guardian);
        vm.prank(guardian);
        vault.pause();
        assertTrue(vault.paused());
        vm.prank(guardian);
        vault.revokeAgent(agent);
        (bool active,,,,,) = _agentCore();
        assertFalse(active);
        vm.prank(guardian);
        vm.expectRevert();
        vault.grantAgent(agent, uint64(block.timestamp + 1 days), SLIP, MAX_TX, DAILY);
        vm.prank(guardian);
        vm.expectRevert();
        vault.unpause();
    }

    function _agentCore() internal view returns (bool, uint64, uint32, uint16, uint128, uint128) {
        (bool active, uint64 expiry, uint32 epoch, uint16 slip, uint128 maxTx, uint128 daily,,) = vault.agents(agent);
        return (active, expiry, epoch, slip, maxTx, daily);
    }

    function test_renounceAgent() public {
        vm.prank(agent);
        vault.renounceAgent();
        (bool active,,,,,,,) = vault.agents(agent);
        assertFalse(active);
    }

    function test_tightenPolicy() public {
        vm.prank(owner);
        vault.setPolicy(agent, uint64(block.timestamp + 1 days), 50, 100e8, 200e8);
        (,,, uint16 slip, uint128 maxTx, uint128 daily,,) = vault.agents(agent);
        assertEq(slip, 50);
        assertEq(maxTx, 100e8);
        assertEq(daily, 200e8);
    }

    function test_invalidPolicyReverts() public {
        vm.startPrank(owner);
        vm.expectRevert(SlipGuardVault.InvalidPolicy.selector);
        vault.grantAgent(makeAddr("a2"), uint64(block.timestamp + 1 days), 2001, 1e8, 2e8);
        vm.expectRevert(SlipGuardVault.InvalidPolicy.selector);
        vault.grantAgent(makeAddr("a2"), uint64(block.timestamp + 1 days), 100, 3e8, 2e8);
        vm.expectRevert(SlipGuardVault.InvalidExpiry.selector);
        vault.grantAgent(makeAddr("a2"), uint64(block.timestamp), 100, 1e8, 2e8);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ caps

    function test_perTxAndDailyUsdCaps() public {
        // $1,000 cap per tx; $3,000 in = should fail
        uint256 tooBig = 1_001e6; // just over $1,000
        uint256 inUsd = vault.quoteUsd(address(usdc), tooBig);
        bytes memory data = _swapCall(address(usdc), address(weth), tooBig, 1, address(vault));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(SlipGuardVault.ExceedsPerTxCap.selector, inUsd, uint256(MAX_TX)));
        vault.executeSwap(address(usdc), address(weth), tooBig, address(router), data);

        // five $1,000 swaps fill the $5,000 daily cap
        uint256 chunk = 1_000e6;
        uint256 minOut = _minOut(address(usdc), address(weth), chunk, SLIP);
        for (uint256 i; i < 5; i++) {
            _agentSwap(address(usdc), address(weth), chunk, minOut);
        }
        uint256 would = vault.quoteUsd(address(usdc), chunk) * 6;
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(SlipGuardVault.ExceedsDailyCap.selector, would, uint256(DAILY)));
        vault.executeSwap(
            address(usdc),
            address(weth),
            chunk,
            address(router),
            _swapCall(address(usdc), address(weth), chunk, minOut, address(vault))
        );

        // next day the window resets
        vm.warp(block.timestamp + 1 days);
        ethUsd.set(ETH_PRICE, block.timestamp);
        usdcUsd.set(USDC_PRICE, block.timestamp);
        minOut = _minOut(address(usdc), address(weth), chunk, SLIP);
        _agentSwap(address(usdc), address(weth), chunk, minOut);
    }

    function test_spendableUsdNow() public {
        (uint256 amt,) = vault.spendableUsdNow(agent);
        assertEq(amt, MAX_TX);
        uint256 chunk = 1_000e6;
        uint256 minOut = _minOut(address(usdc), address(weth), chunk, SLIP);
        _agentSwap(address(usdc), address(weth), chunk, minOut);
        (amt,) = vault.spendableUsdNow(agent);
        assertEq(amt, 1_000e8); // still $1,000 per tx, $4,000 daily left
    }

    // ------------------------------------------------------------------ oracle

    function test_staleFeedReverts() public {
        vm.warp(block.timestamp + 2 hours);
        usdcUsd.set(USDC_PRICE, block.timestamp); // usdc fresh, eth stale
        vm.prank(agent);
        vm.expectRevert(SlipGuardVault.StaleOrInvalidPrice.selector);
        vault.executeSwap(
            address(usdc),
            address(weth),
            1e6,
            address(router),
            _swapCall(address(usdc), address(weth), 1e6, 1, address(vault))
        );
    }

    function test_missingFeedReverts() public {
        MockUSDC other = new MockUSDC();
        vm.prank(owner);
        vault.setTokenAllowed(agent, address(other), true);
        vm.prank(agent);
        vm.expectRevert(SlipGuardVault.NoFeed.selector);
        vault.executeSwap(
            address(usdc),
            address(other),
            1e6,
            address(router),
            _swapCall(address(usdc), address(other), 1e6, 1, address(vault))
        );
    }

    function test_negativeOrZeroPriceReverts() public {
        ethUsd.set(0, block.timestamp);
        vm.prank(agent);
        vm.expectRevert(SlipGuardVault.StaleOrInvalidPrice.selector);
        vault.quoteUsd(address(weth), 1 ether);
    }

    function test_quoteMatchesManualMath() public view {
        // 3,000 USDC * $1 = $3,000 = 3000e8
        assertEq(vault.quoteUsd(address(usdc), 3_000e6), 3_000e8);
        // 1 WETH * $3,000 = $3,000
        assertEq(vault.quoteUsd(address(weth), 1 ether), 3_000e8);
        // minOut of 3000 USDC -> WETH at 1% slip: 0.99 ETH
        uint256 minOut = vault.previewMinOut(address(usdc), address(weth), 3_000e6, 100);
        assertEq(minOut, 0.99 ether);
    }

    // ------------------------------------------------------------------ approvals / eth

    function test_overpullRevertsAndDoesNotLeaveApproval() public {
        bytes memory data = abi.encodeWithSelector(MockRouter.overpull.selector, address(usdc), address(vault), 2_000e6);
        vm.prank(agent);
        vm.expectRevert(); // either allowance fail or ExcessInputPulled if somehow approved more
        vault.executeSwap(address(usdc), address(weth), 1_000e6, address(router), data);
        assertEq(usdc.allowance(address(vault), address(router)), 0);
    }

    function test_routerCannotCallWithdraw() public {
        bytes memory data =
            abi.encodeWithSelector(MockRouter.tryWithdraw.selector, address(vault), address(usdc), agent, 1e6);
        vm.prank(agent);
        vm.expectRevert();
        vault.executeSwap(address(usdc), address(weth), 1e6, address(router), data);
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_minOutBoundary(uint256 amountIn, uint256 outDelta) public {
        amountIn = bound(amountIn, 1e6, 1_000e6); // up to $1,000, within per-tx cap
        uint256 minOut = _minOut(address(usdc), address(weth), amountIn, SLIP);
        // fund router enough (already has lots of WETH? router holds USDC; for WETH out we need WETH in router)
        vm.deal(address(this), 100 ether);
        weth.deposit{value: 100 ether}();
        weth.transfer(address(router), 100 ether);

        outDelta = bound(outDelta, 0, 2);
        if (outDelta == 0) {
            // exactly minOut succeeds
            uint256 got = _agentSwap(address(usdc), address(weth), amountIn, minOut);
            assertEq(got, minOut);
        } else if (outDelta == 1 && minOut > 0) {
            bytes memory data = _swapCall(address(usdc), address(weth), amountIn, minOut - 1, address(vault));
            vm.prank(agent);
            vm.expectRevert(abi.encodeWithSelector(SlipGuardVault.SlippageExceeded.selector, minOut - 1, minOut));
            vault.executeSwap(address(usdc), address(weth), amountIn, address(router), data);
        } else {
            uint256 extra = minOut + 1;
            uint256 got = _agentSwap(address(usdc), address(weth), amountIn, extra);
            assertEq(got, extra);
        }
    }

    function testFuzz_capsNeverExceeded(uint256 a1, uint256 a2, uint256 a3) public {
        a1 = bound(a1, 1e6, 2_000e6);
        a2 = bound(a2, 1e6, 2_000e6);
        a3 = bound(a3, 1e6, 2_000e6);
        uint256 spent;
        uint256[3] memory amts = [a1, a2, a3];
        for (uint256 i; i < 3; i++) {
            uint256 amountIn = amts[i];
            uint256 inUsd = vault.quoteUsd(address(usdc), amountIn);
            uint256 minOut = _minOut(address(usdc), address(weth), amountIn, SLIP);
            vm.deal(address(this), 50 ether);
            weth.deposit{value: 50 ether}();
            weth.transfer(address(router), 50 ether);
            bytes memory data = _swapCall(address(usdc), address(weth), amountIn, minOut, address(vault));
            vm.prank(agent);
            if (inUsd > MAX_TX || spent + inUsd > DAILY) {
                vm.expectRevert();
                vault.executeSwap(address(usdc), address(weth), amountIn, address(router), data);
            } else {
                vault.executeSwap(address(usdc), address(weth), amountIn, address(router), data);
                spent += inUsd;
            }
        }
        (,,,,,, uint64 ws, uint128 windowSpent) = vault.agents(agent);
        ws; // silence
        assertLe(windowSpent, DAILY);
        assertLe(spent, DAILY);
    }

    function testFuzz_slippagePreview(uint16 slip, uint256 amountIn) public view {
        slip = uint16(bound(slip, 0, 2_000));
        amountIn = bound(amountIn, 1e6, 100_000e6);
        uint256 minOut = vault.previewMinOut(address(usdc), address(weth), amountIn, slip);
        // 3000 USDC -> 1 ETH mid; general: amountIn (6 dec) * 1e8 / 3000e8 * 1e18 * (10000-slip)/10000
        uint256 mid = (amountIn * 1e18) / 3_000e6;
        uint256 expected = mid * (10_000 - slip) / 10_000;
        // slippage is applied in USD space, so token-space mid*bps can differ by a few units
        assertLe(minOut, mid);
        assertApproxEqRel(minOut, expected, 1e12); // 0.0001%
    }
}
