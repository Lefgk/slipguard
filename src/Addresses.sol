// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Canonical token, router and Chainlink feed addresses for Ethereum and Base.
///         Verified to have bytecode on a live-chain fork in `test/fork`.
library Addresses {
    uint256 internal constant ETHEREUM = 1;
    uint256 internal constant BASE = 8453;
    uint256 internal constant ANVIL = 31337;

    address internal constant USDC_ETHEREUM = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH_ETHEREUM = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WETH_BASE = 0x4200000000000000000000000000000000000006;

    // Uniswap Universal Router in the v3 deployments list (widely used).
    address internal constant UR_ETHEREUM = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address internal constant UR_BASE = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    // Universal Router 2.1.2 (current Uniswap Trading API default as of 2026).
    address internal constant UR_212_ETHEREUM = 0x23617e59A5925b2A4Bf75d73ff6711cD0b29De85;
    address internal constant UR_212_BASE = 0xd6145b2D3F379919E8CdEda7B97e37c4b2Ca9c40;
    address internal constant SWAP_ROUTER02_ETHEREUM = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address internal constant SWAP_ROUTER02_BASE = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address internal constant INCH_V6 = 0x111111125421cA6dc452d289314280a0f8842A65;
    address internal constant ZEROX_PROXY = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF;
    address internal constant ZEROX_SETTLER_ETHEREUM = 0xaddC26a3854feaBFd20d6BF658254088D83a425A;
    address internal constant ZEROX_SETTLER_BASE = 0x103502909141F7025a94b7b99A276dCD128e21a8;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address internal constant ETH_USD_ETHEREUM = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address internal constant USDC_USD_ETHEREUM = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address internal constant ETH_USD_BASE = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address internal constant USDC_USD_BASE = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;

    address internal constant V3_FACTORY_ETHEREUM = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address internal constant V3_FACTORY_BASE = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;

    // Recommended feed heartbeats (with a short buffer over typical Chainlink values).
    uint64 internal constant ETH_USD_STALE = 1 hours + 15 minutes;
    uint64 internal constant USDC_USD_STALE = 24 hours + 1 hours;

    struct Chain {
        string name;
        bool isMainnet;
        address usdc;
        address weth;
        address universalRouter;
        address universalRouter212;
        address swapRouter02;
        address inchV6;
        address zeroxProxy;
        address zeroxSettler;
        address ethUsd;
        address usdcUsd;
        address v3Factory;
    }

    function get(uint256 chainId) internal pure returns (Chain memory) {
        if (chainId == ETHEREUM) {
            return Chain(
                "Ethereum mainnet",
                true,
                USDC_ETHEREUM,
                WETH_ETHEREUM,
                UR_ETHEREUM,
                UR_212_ETHEREUM,
                SWAP_ROUTER02_ETHEREUM,
                INCH_V6,
                ZEROX_PROXY,
                ZEROX_SETTLER_ETHEREUM,
                ETH_USD_ETHEREUM,
                USDC_USD_ETHEREUM,
                V3_FACTORY_ETHEREUM
            );
        }
        if (chainId == BASE) {
            return Chain(
                "Base",
                true,
                USDC_BASE,
                WETH_BASE,
                UR_BASE,
                UR_212_BASE,
                SWAP_ROUTER02_BASE,
                INCH_V6,
                ZEROX_PROXY,
                ZEROX_SETTLER_BASE,
                ETH_USD_BASE,
                USDC_USD_BASE,
                V3_FACTORY_BASE
            );
        }
        if (chainId == ANVIL) {
            return Chain("Local anvil", false, address(0), address(0), address(0), address(0), address(0), address(0), address(0), address(0), address(0), address(0), address(0));
        }
        revert("Addresses: unsupported chain (only 1, 8453, 31337)");
    }

    function suggestedRouters(uint256 chainId) internal pure returns (address[] memory routers) {
        Chain memory c = get(chainId);
        routers = new address[](6);
        routers[0] = c.universalRouter;
        routers[1] = c.universalRouter212;
        routers[2] = c.swapRouter02;
        routers[3] = c.inchV6;
        routers[4] = c.zeroxProxy;
        routers[5] = c.zeroxSettler;
    }
}
