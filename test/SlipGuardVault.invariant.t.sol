// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SlipGuardVault} from "../src/SlipGuardVault.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockWETH} from "../src/MockWETH.sol";
import {MockAggregator} from "../src/mocks/MockAggregator.sol";
import {MockRouter} from "../src/mocks/MockRouter.sol";

contract Handler is Test {
    SlipGuardVault public vault;
    MockUSDC public usdc;
    MockWETH public weth;
    MockRouter public router;
    address public owner;
    address public agent;
    uint16 public constant SLIP = 100;
    uint128 public constant MAX_TX = 1_000e8;
    uint128 public constant DAILY = 5_000e8;

    uint256 public ghostMaxUsdInTx;
    uint256 public ghostMaxUsdInWindow;
    mapping(uint64 => uint256) public ghostSpentInWindow;
    uint256 public ghostMinOutFailures; // successful swap that broke min-out (should stay 0)
    uint256 public ghostAgentReceived;
    uint256 public ghostEthDrained;
    uint256 public ghostSwapsWhileInactive;
    uint256 public ghostSuccessfulSwaps;
    uint256 public calls;
    uint256 public ethBaseline;

    constructor(
        SlipGuardVault v,
        MockUSDC u,
        MockWETH w,
        MockRouter r,
        address o,
        address a
    ) {
        vault = v;
        usdc = u;
        weth = w;
        router = r;
        owner = o;
        agent = a;
        ethBaseline = address(v).balance;
    }

    function swap(uint256 amountIn, uint256 quality, uint256 recipientPick) external {
        calls++;
        amountIn = bound(amountIn, 1e6, 2_000e6);
        quality = bound(quality, 0, 4);
        _swap(amountIn, quality, recipientPick % 7 == 0 ? agent : address(vault));
    }

    function _swap(uint256 amountIn, uint256 quality, address recipient) internal {
        address tokenIn = quality % 2 == 0 ? address(usdc) : address(weth);
        address tokenOut = tokenIn == address(usdc) ? address(weth) : address(usdc);
        uint256 minOut;
        try vault.previewMinOut(tokenIn, tokenOut, amountIn, SLIP) returns (uint256 m) {
            minOut = m;
        } catch {
            return;
        }
        uint256 pay = quality <= 2 ? minOut : (quality == 3 ? minOut + minOut / 100 + 1 : (minOut == 0 ? 0 : minOut - 1));
        _attempt(tokenIn, tokenOut, amountIn, pay, minOut, recipient);
    }

    function _attempt(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 pay,
        uint256 minOut,
        address recipient
    ) internal {
        (bool activeBefore,,,,,,,) = vault.agents(agent);
        bool pausedBefore = vault.paused();
        uint256 ethBefore = address(vault).balance;
        uint256 agentBefore = usdc.balanceOf(agent) + weth.balanceOf(agent);
        vm.prank(agent);
        try vault.executeSwap(
            tokenIn,
            tokenOut,
            amountIn,
            address(router),
            abi.encodeCall(MockRouter.swap, (tokenIn, tokenOut, amountIn, pay, address(vault), recipient))
        ) {
            if (!activeBefore || pausedBefore) ghostSwapsWhileInactive++;
            if (pay < minOut || recipient != address(vault)) ghostMinOutFailures++;
            _recordSuccess(tokenIn, amountIn);
        } catch {}
        if (address(vault).balance < ethBefore) ghostEthDrained += ethBefore - address(vault).balance;
        ghostAgentReceived += (usdc.balanceOf(agent) + weth.balanceOf(agent)) - agentBefore;
    }

    function _recordSuccess(address tokenIn, uint256 amountIn) internal {
        uint256 inUsd = vault.quoteUsd(tokenIn, amountIn);
        if (inUsd > ghostMaxUsdInTx) ghostMaxUsdInTx = inUsd;
        (,,,,,, uint64 ws,) = vault.agents(agent);
        ghostSpentInWindow[ws] += inUsd;
        if (ghostSpentInWindow[ws] > ghostMaxUsdInWindow) ghostMaxUsdInWindow = ghostSpentInWindow[ws];
        ghostSuccessfulSwaps++;
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 2 days));
        // keep mock feeds fresh so stale-oracle isn't the only path
        // (feeds are updated by the test contract via a cheat on storage-less mocks: the handler
        // cannot call set() unless it is the owner of the mocks; the invariant contract exposes a hook.)
    }

    function togglePause(bool p) external {
        bool isPaused = vault.paused();
        vm.prank(owner);
        if (p && !isPaused) vault.pause();
        else if (!p && isPaused) vault.unpause();
    }

    function revokeAndRegrant(bool regrant) external {
        vm.startPrank(owner);
        vault.revokeAgent(agent);
        if (regrant) {
            vault.grantAgent(agent, uint64(block.timestamp + 365 days), SLIP, MAX_TX, DAILY);
            vault.setTokenAllowed(agent, address(usdc), true);
            vault.setTokenAllowed(agent, address(weth), true);
            vault.setRouterAllowed(agent, address(router), true);
        }
        vm.stopPrank();
    }
}

contract SlipGuardVaultInvariantTest is Test {
    SlipGuardVault vault;
    MockUSDC usdc;
    MockWETH weth;
    MockAggregator ethUsd;
    MockAggregator usdcUsd;
    MockRouter router;
    Handler handler;
    address owner = makeAddr("owner");
    address agent = makeAddr("agent");

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockUSDC();
        weth = new MockWETH();
        vault = new SlipGuardVault(owner, address(weth));
        ethUsd = new MockAggregator(3_000e8, block.timestamp);
        usdcUsd = new MockAggregator(1e8, block.timestamp);
        router = new MockRouter();

        usdc.mint(address(vault), 1_000_000e6);
        usdc.mint(address(router), 1_000_000e6);
        vm.deal(address(this), 2_000 ether);
        weth.deposit{value: 2_000 ether}();
        weth.transfer(address(vault), 200 ether);
        weth.transfer(address(router), 1_800 ether);

        vm.startPrank(owner);
        vault.setFeed(address(weth), address(ethUsd), 30 days); // long stale window so warp does not trip oracle
        vault.setFeed(address(usdc), address(usdcUsd), 30 days);
        vault.grantAgent(agent, uint64(block.timestamp + 365 days), 100, 1_000e8, 5_000e8);
        vault.setTokenAllowed(agent, address(usdc), true);
        vault.setTokenAllowed(agent, address(weth), true);
        vault.setRouterAllowed(agent, address(router), true);
        vm.stopPrank();

        handler = new Handler(vault, usdc, weth, router, owner, agent);
        targetContract(address(handler));
        address fuzzCaller = makeAddr("fuzz-caller");
        vm.deal(fuzzCaller, 1_000 ether);
        targetSender(fuzzCaller);
    }

    function invariant_perTxCapNeverExceeded() public view {
        assertLe(handler.ghostMaxUsdInTx(), handler.MAX_TX());
    }

    function invariant_dailyCapNeverExceeded() public view {
        assertLe(handler.ghostMaxUsdInWindow(), handler.DAILY());
        (,,,,,,, uint128 spent) = vault.agents(agent);
        assertLe(spent, handler.DAILY());
    }

    function invariant_minOutAlwaysHolds() public view {
        assertEq(handler.ghostMinOutFailures(), 0);
    }

    function invariant_agentNeverReceivesFunds() public view {
        assertEq(handler.ghostAgentReceived(), 0);
        assertEq(usdc.balanceOf(agent), 0);
        assertEq(weth.balanceOf(agent), 0);
    }

    function invariant_agentCannotMoveEth() public view {
        assertEq(handler.ghostEthDrained(), 0);
        assertEq(address(vault).balance, handler.ethBaseline());
    }

    function invariant_noSwapWhilePausedOrRevoked() public view {
        assertEq(handler.ghostSwapsWhileInactive(), 0);
    }

    function invariant_approvalsCleared() public view {
        assertEq(usdc.allowance(address(vault), address(router)), 0);
        assertEq(weth.allowance(address(vault), address(router)), 0);
    }
}
