// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SlipGuardVault} from "../../src/SlipGuardVault.sol";
import {SlipGuardVaultFactory} from "../../src/SlipGuardVaultFactory.sol";
import {Addresses} from "../../src/Addresses.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

interface IFiatToken {
    function masterMinter() external view returns (address);
    function configureMinter(address minter, uint256 minterAllowedAmount) external returns (bool);
    function mint(address to, uint256 amount) external returns (bool);
}

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/// @dev Fork tests: real USDC/WETH swap through Uniswap SwapRouter02 with the Chainlink min-out check.
///      Run with `forge test --fork-url http://127.0.0.1:8624` (or MAINNET_FORK_RPC / BASE_FORK_RPC).
abstract contract ForkBase is Test {
    SlipGuardVaultFactory factory;
    SlipGuardVault vault;
    IERC20Metadata usdc;
    IERC20Metadata weth;
    Addresses.Chain cfg;
    address owner = makeAddr("fork-owner");
    address agent = makeAddr("fork-agent");
    address stranger = makeAddr("fork-stranger");
    bool active;

    uint16 constant SLIP = 200; // 2% — covers Chainlink vs pool deviation
    uint128 constant MAX_TX = 10_000e8;
    uint128 constant DAILY = 50_000e8;
    uint256 constant AMOUNT_IN = 1_000e6; // 1,000 USDC

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
        cfg = Addresses.get(block.chainid);
        usdc = IERC20Metadata(cfg.usdc);
        weth = IERC20Metadata(cfg.weth);

        factory = new SlipGuardVaultFactory(cfg.weth);
        vm.prank(owner);
        vault = SlipGuardVault(payable(factory.createVault()));

        _fundUsdc(owner, 10_000e6);
        vm.deal(owner, 10 ether);

        vm.startPrank(owner);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(address(usdc), 5_000e6);
        vault.setFeed(cfg.weth, cfg.ethUsd, Addresses.ETH_USD_STALE);
        vault.setFeed(cfg.usdc, cfg.usdcUsd, Addresses.USDC_USD_STALE);
        vault.grantAgent(agent, uint64(block.timestamp + 7 days), SLIP, MAX_TX, DAILY);
        vault.setTokenAllowed(agent, cfg.usdc, true);
        vault.setTokenAllowed(agent, cfg.weth, true);
        vault.setRouterAllowed(agent, cfg.swapRouter02, true);
        vault.setRouterAllowed(agent, cfg.universalRouter, true);
        vault.setRouterAllowed(agent, cfg.universalRouter212, true);
        vault.setRouterAllowed(agent, cfg.inchV6, true);
        vault.setRouterAllowed(agent, cfg.zeroxProxy, true);
        vault.setRouterAllowed(agent, cfg.zeroxSettler, true);
        vm.stopPrank();
    }

    modifier onFork() {
        if (!active) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _fundUsdc(address to, uint256 amount) internal {
        // Prefer Circle's minter; fall back to `deal` if the ABI is unexpected.
        try IFiatToken(address(usdc)).masterMinter() returns (address minter) {
            vm.prank(minter);
            IFiatToken(address(usdc)).configureMinter(address(this), type(uint256).max);
            IFiatToken(address(usdc)).mint(to, amount);
        } catch {
            deal(address(usdc), to, amount, true);
        }
        require(usdc.balanceOf(to) >= amount, "USDC funding failed");
    }

    function _bestFee() internal view returns (uint24 fee) {
        IUniswapV3Factory fac = IUniswapV3Factory(cfg.v3Factory);
        uint24[3] memory fees = [uint24(500), uint24(3000), uint24(100)];
        for (uint256 i; i < fees.length; i++) {
            address pool = fac.getPool(cfg.usdc, cfg.weth, fees[i]);
            if (pool != address(0) && pool.code.length > 0) return fees[i];
        }
        revert("no USDC/WETH pool");
    }

    function _exactInputData(uint256 amountIn, address recipient, uint256 amountOutMin)
        internal
        view
        returns (bytes memory)
    {
        ISwapRouter02.ExactInputSingleParams memory p = ISwapRouter02.ExactInputSingleParams({
            tokenIn: cfg.usdc,
            tokenOut: cfg.weth,
            fee: _bestFee(),
            recipient: recipient,
            amountIn: amountIn,
            amountOutMinimum: amountOutMin,
            sqrtPriceLimitX96: 0
        });
        return abi.encodeWithSelector(ISwapRouter02.exactInputSingle.selector, p);
    }

    function test_fork_realUsdcAndFeeds() public onFork {
        assertEq(usdc.symbol(), "USDC");
        assertEq(usdc.decimals(), 6);
        assertGt(address(usdc).code.length, 0);
        assertGt(address(weth).code.length, 0);
        assertEq(usdc.balanceOf(address(vault)), 5_000e6);

        (, int256 ethPrice,, uint256 ethUpdated,) = AggregatorV3Interface(cfg.ethUsd).latestRoundData();
        (, int256 usdcPrice,, uint256 usdcUpdated,) = AggregatorV3Interface(cfg.usdcUsd).latestRoundData();
        assertGt(ethPrice, 0);
        assertGt(usdcPrice, 0);
        assertGt(ethUpdated, 0);
        assertGt(usdcUpdated, 0);
        assertGt(vault.quoteUsd(cfg.usdc, 1_000e6), 0);
        assertGt(vault.previewMinOut(cfg.usdc, cfg.weth, 1_000e6, SLIP), 0);
    }

    function test_fork_knownRoutersHaveCode() public onFork {
        address[] memory routers = Addresses.suggestedRouters(block.chainid);
        for (uint256 i; i < routers.length; i++) {
            assertGt(routers[i].code.length, 0, "router missing code");
        }
        assertGt(Addresses.PERMIT2.code.length, 0, "Permit2 missing");
        assertGt(cfg.ethUsd.code.length, 0, "ETH/USD feed missing");
        assertGt(cfg.usdcUsd.code.length, 0, "USDC/USD feed missing");
        assertGt(cfg.v3Factory.code.length, 0, "V3 factory missing");
        assertTrue(vault.isRouterAllowed(agent, cfg.swapRouter02));
        assertTrue(vault.isRouterAllowed(agent, cfg.universalRouter));
        assertTrue(vault.isRouterAllowed(agent, cfg.inchV6));
        assertTrue(vault.isRouterAllowed(agent, cfg.zeroxProxy));
    }

    function test_fork_realUsdcWethSwapThroughUniswap() public onFork {
        uint256 minOut = vault.previewMinOut(cfg.usdc, cfg.weth, AMOUNT_IN, SLIP);
        assertGt(minOut, 0);

        uint256 usdcBefore = usdc.balanceOf(address(vault));
        uint256 wethBefore = weth.balanceOf(address(vault));
        uint256 ownerUsdc = usdc.balanceOf(owner);
        uint256 agentWeth = weth.balanceOf(agent);
        uint256 ethBefore = address(vault).balance;

        bytes memory data = _exactInputData(AMOUNT_IN, address(vault), 0);
        vm.prank(agent);
        uint256 amountOut = vault.executeSwap(cfg.usdc, cfg.weth, AMOUNT_IN, cfg.swapRouter02, data);

        assertGe(amountOut, minOut, "min-out must hold");
        assertEq(usdc.balanceOf(address(vault)), usdcBefore - AMOUNT_IN);
        assertEq(weth.balanceOf(address(vault)), wethBefore + amountOut);
        assertEq(usdc.balanceOf(owner), ownerUsdc, "must not pull from owner wallet");
        assertEq(weth.balanceOf(agent), agentWeth, "output must stay in the vault");
        assertEq(address(vault).balance, ethBefore, "ETH must not move");
        assertEq(usdc.allowance(address(vault), cfg.swapRouter02), 0);
    }

    function test_fork_swapRevertsWhenOracleMinOutNotMet() public onFork {
        // Pretend ETH is $1 so min-out is enormous relative to the real pool.
        vm.mockCall(
            cfg.ethUsd,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(1e8), uint256(block.timestamp), uint256(block.timestamp), uint80(1))
        );
        uint256 minOut = vault.previewMinOut(cfg.usdc, cfg.weth, AMOUNT_IN, SLIP);
        // 1000 USDC / $1 ETH * 0.98 ≈ 980 ETH, far above any real quote
        assertGt(minOut, 100 ether);

        bytes memory data = _exactInputData(AMOUNT_IN, address(vault), 0);
        vm.prank(agent);
        vm.expectRevert();
        vault.executeSwap(cfg.usdc, cfg.weth, AMOUNT_IN, cfg.swapRouter02, data);

        assertEq(usdc.balanceOf(address(vault)), 5_000e6, "swap must fully revert");
    }

    function test_fork_swapToAgentRecipientReverts() public onFork {
        uint256 minOut = vault.previewMinOut(cfg.usdc, cfg.weth, AMOUNT_IN, SLIP);
        bytes memory data = _exactInputData(AMOUNT_IN, agent, 0);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(SlipGuardVault.SlippageExceeded.selector, 0, minOut));
        vault.executeSwap(cfg.usdc, cfg.weth, AMOUNT_IN, cfg.swapRouter02, data);
        assertEq(weth.balanceOf(agent), 0);
    }
}

contract EthereumSlipGuardForkTest is ForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "MAINNET_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 1;
    }
}

contract BaseSlipGuardForkTest is ForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "BASE_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 8453;
    }
}
