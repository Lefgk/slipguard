// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IPermit2} from "./interfaces/IPermit2.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @title SlipGuardVault
/// @notice Owner-funded personal vault that grants an AI agent capped, time-limited swap rights.
///         The agent may only call allowlisted routers with allowlisted tokens. Min-out is enforced
///         on-chain from the vault's tokenOut balance delta versus a Chainlink mid price minus
///         `maxSlippageBps`. Output stays in the vault. The agent cannot withdraw.
/// @dev    PROTOTYPE - NOT AUDITED. ERC-20 swaps only (`executeSwap` never sends ETH).
contract SlipGuardVault is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant BPS_DENOM = 10_000;
    uint16 public constant MAX_SLIPPAGE_BPS = 2_000; // owner cannot grant more than 20%
    uint64 public constant PERIOD = 1 days;
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    /// @notice Chainlink L2 sequencer uptime feed on Base; used only when deployed on chain 8453.
    address public constant BASE_SEQUENCER_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    uint256 public constant SEQUENCER_GRACE = 1 hours;

    struct Agent {
        bool active;
        uint64 expiry;
        uint32 epoch;
        uint16 maxSlippageBps;
        uint128 maxPerTxUsd; // 8 decimals, $1 = 1e8
        uint128 dailyCapUsd; // 8 decimals
        uint64 windowStart;
        uint128 spentUsdInWindow;
    }

    struct Feed {
        address aggregator;
        uint64 maxStale;
        uint8 decimals;
    }

    struct SwapPrep {
        uint256 inUsd;
        uint256 wouldSpend;
        uint256 minOut;
        uint256 ethBefore;
        uint256 inBefore;
        uint256 outBefore;
    }

    address public immutable weth;
    /// @notice address(0) on chains without a sequencer (Ethereum, anvil).
    address public immutable sequencerFeed;
    address public guardian;
    /// @notice When true, `executeSwap` also grants a one-shot Permit2 allowance to the router
    ///         (needed for Uniswap Universal Router). Off by default.
    bool public permit2Enabled;

    mapping(address agent => Agent) public agents;
    mapping(address token => Feed) public feeds;
    /// @dev keccak256(agent, epoch, token)
    mapping(bytes32 key => bool) internal _tokenAllowed;
    /// @dev keccak256(agent, epoch, router)
    mapping(bytes32 key => bool) internal _routerAllowed;

    event Deposited(address indexed from, address indexed token, uint256 amount);
    event Withdrawn(address indexed to, address indexed token, uint256 amount);
    event Wrapped(uint256 amount);
    event Unwrapped(uint256 amount);
    event GuardianSet(address indexed guardian);
    event Permit2Enabled(bool enabled);
    event FeedSet(address indexed token, address indexed aggregator, uint64 maxStale, uint8 decimals);
    event AgentGranted(
        address indexed agent, uint64 expiry, uint16 maxSlippageBps, uint128 maxPerTxUsd, uint128 dailyCapUsd, uint32 epoch
    );
    event PolicySet(address indexed agent, uint64 expiry, uint16 maxSlippageBps, uint128 maxPerTxUsd, uint128 dailyCapUsd);
    event AgentRevoked(address indexed agent, address indexed by, uint32 newEpoch);
    event TokenAllowed(address indexed agent, address indexed token, bool allowed);
    event RouterAllowed(address indexed agent, address indexed router, bool allowed);
    event Swapped(
        address indexed agent,
        address indexed tokenIn,
        address indexed tokenOut,
        address router,
        uint256 amountIn,
        uint256 amountOut,
        uint256 minOut,
        uint256 usdIn,
        uint256 spentUsdInWindow,
        uint64 windowStart
    );

    error NotAgent();
    error AgentExpired();
    error InvalidToken();
    error InvalidRouter();
    error TokenNotAllowed();
    error RouterNotAllowed();
    error InvalidPolicy();
    error InvalidExpiry();
    error InvalidFeed();
    error NoFeed();
    error StaleOrInvalidPrice();
    error ZeroAddress();
    error ZeroAmount();
    error NotOwnerOrGuardian();
    error ExceedsPerTxCap(uint256 usd, uint256 cap);
    error ExceedsDailyCap(uint256 wouldSpend, uint256 cap);
    error SlippageExceeded(uint256 amountOut, uint256 minOut);
    error ExcessInputPulled(uint256 pulled, uint256 maxIn);
    error EthMoved();
    error InsufficientBalance();
    error InvalidOracleMinOut();
    error EthTransferFailed();
    error AmountTooLargeForPermit2();
    error SequencerDown();
    error SequencerGracePeriod();

    modifier onlyOwnerOrGuardian() {
        if (msg.sender != owner() && msg.sender != guardian) revert NotOwnerOrGuardian();
        _;
    }

    constructor(address initialOwner, address weth_) Ownable(initialOwner) {
        if (weth_ == address(0)) revert ZeroAddress();
        weth = weth_;
        sequencerFeed = block.chainid == 8453 ? BASE_SEQUENCER_FEED : address(0);
    }

    receive() external payable {
        emit Deposited(msg.sender, address(0), msg.value);
    }

    // ------------------------------------------------------------------ funding

    /// @notice Pull ERC-20 into the vault (needs prior approve). Records the amount actually received.
    function deposit(address token, uint256 amount) external nonReentrant {
        if (token == address(0)) revert InvalidToken();
        if (amount == 0) revert ZeroAmount();
        uint256 before_ = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, token, IERC20(token).balanceOf(address(this)) - before_);
    }

    /// @notice Wrap the vault's entire ETH balance to WETH. Anyone may call; funds stay in the vault.
    function wrapETH() external nonReentrant returns (uint256 amount) {
        amount = address(this).balance;
        if (amount == 0) revert ZeroAmount();
        IWETH(weth).deposit{value: amount}();
        emit Wrapped(amount);
    }

    /// @notice Owner unwraps WETH to ETH. Works while paused.
    function unwrapWETH(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IWETH(weth).withdraw(amount);
        emit Unwrapped(amount);
    }

    /// @notice Owner withdraws ERC-20. Works while paused so funds are never stuck.
    function withdraw(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(0)) revert InvalidToken();
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(to, token, amount);
    }

    /// @notice Owner withdraws native ETH. Works while paused.
    function withdrawETH(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit Withdrawn(to, address(0), amount);
    }

    // ------------------------------------------------------------------ admin

    function setGuardian(address newGuardian) external onlyOwner {
        guardian = newGuardian;
        emit GuardianSet(newGuardian);
    }

    function setPermit2Enabled(bool enabled) external onlyOwner {
        permit2Enabled = enabled;
        emit Permit2Enabled(enabled);
    }

    function setFeed(address token, address aggregator, uint64 maxStale) external onlyOwner {
        if (token == address(0) || aggregator == address(0)) revert ZeroAddress();
        if (maxStale == 0) revert InvalidFeed();
        uint8 dec = AggregatorV3Interface(aggregator).decimals();
        feeds[token] = Feed({aggregator: aggregator, maxStale: maxStale, decimals: dec});
        emit FeedSet(token, aggregator, maxStale, dec);
    }

    function grantAgent(
        address agent,
        uint64 expiry,
        uint16 maxSlippageBps,
        uint128 maxPerTxUsd,
        uint128 dailyCapUsd
    ) external onlyOwner {
        if (agent == address(0)) revert ZeroAddress();
        _validatePolicy(expiry, maxSlippageBps, maxPerTxUsd, dailyCapUsd);
        Agent storage a = agents[agent];
        a.active = true;
        a.expiry = expiry;
        a.maxSlippageBps = maxSlippageBps;
        a.maxPerTxUsd = maxPerTxUsd;
        a.dailyCapUsd = dailyCapUsd;
        if (a.windowStart == 0) a.windowStart = uint64(block.timestamp);
        emit AgentGranted(agent, expiry, maxSlippageBps, maxPerTxUsd, dailyCapUsd, a.epoch);
    }

    /// @notice Update caps, slippage or expiry without wiping allowlists or the daily window counter.
    function setPolicy(address agent, uint64 expiry, uint16 maxSlippageBps, uint128 maxPerTxUsd, uint128 dailyCapUsd)
        external
        onlyOwner
    {
        Agent storage a = agents[agent];
        if (!a.active) revert NotAgent();
        _validatePolicy(expiry, maxSlippageBps, maxPerTxUsd, dailyCapUsd);
        a.expiry = expiry;
        a.maxSlippageBps = maxSlippageBps;
        a.maxPerTxUsd = maxPerTxUsd;
        a.dailyCapUsd = dailyCapUsd;
        emit PolicySet(agent, expiry, maxSlippageBps, maxPerTxUsd, dailyCapUsd);
    }

    function setTokenAllowed(address agent, address token, bool allowed) external onlyOwner {
        if (token == address(0)) revert InvalidToken();
        _tokenAllowed[_key(agent, agents[agent].epoch, token)] = allowed;
        emit TokenAllowed(agent, token, allowed);
    }

    function setRouterAllowed(address agent, address router, bool allowed) external onlyOwner {
        if (router == address(0) || router == address(this)) revert InvalidRouter();
        _routerAllowed[_key(agent, agents[agent].epoch, router)] = allowed;
        emit RouterAllowed(agent, router, allowed);
    }

    function revokeAgent(address agent) external onlyOwnerOrGuardian {
        _revoke(agent);
    }

    function renounceAgent() external {
        if (!agents[msg.sender].active) revert NotAgent();
        _revoke(msg.sender);
    }

    function pause() external onlyOwnerOrGuardian {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ------------------------------------------------------------------ agent

    /// @notice Agent swaps `amountIn` of `tokenIn` through an allowlisted `router`.
    ///         Output must arrive in this vault and beat the Chainlink min-out. Never pulls from
    ///         the owner's wallet; never sends ETH; leftover approvals are cleared.
    function executeSwap(address tokenIn, address tokenOut, uint256 amountIn, address router, bytes calldata data)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 amountOut)
    {
        SwapPrep memory p = _prepareSwap(tokenIn, tokenOut, amountIn, router);

        _approveRouter(tokenIn, router, amountIn);
        (bool ok, bytes memory ret) = router.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        _clearApprovals(tokenIn, router);

        amountOut = _finalizeSwap(tokenIn, tokenOut, amountIn, p);
        emit Swapped(
            msg.sender,
            tokenIn,
            tokenOut,
            router,
            amountIn,
            amountOut,
            p.minOut,
            p.inUsd,
            p.wouldSpend,
            agents[msg.sender].windowStart
        );
    }

    // ------------------------------------------------------------------ views

    function isTokenAllowed(address agent, address token) external view returns (bool) {
        return _tokenAllowed[_key(agent, agents[agent].epoch, token)];
    }

    function isRouterAllowed(address agent, address router) external view returns (bool) {
        return _routerAllowed[_key(agent, agents[agent].epoch, router)];
    }

    function quoteUsd(address token, uint256 amount) external view returns (uint256) {
        return _usd8(token, amount);
    }

    function previewMinOut(address tokenIn, address tokenOut, uint256 amountIn, uint16 slippageBps)
        external
        view
        returns (uint256)
    {
        return _minOut(tokenIn, tokenOut, amountIn, slippageBps);
    }

    /// @notice Remaining USD (8 decimals) the agent can swap in one tx right now, and when the daily window ends.
    function spendableUsdNow(address agent) external view returns (uint256 amount, uint64 windowEnd) {
        Agent memory a = agents[agent];
        if (a.dailyCapUsd == 0) return (0, 0);
        (uint64 ws, uint128 spent) = _currentWindow(a);
        windowEnd = ws + PERIOD;
        if (!a.active || block.timestamp >= a.expiry || paused()) return (0, windowEnd);
        uint256 left = a.dailyCapUsd > spent ? a.dailyCapUsd - spent : 0;
        amount = left < a.maxPerTxUsd ? left : a.maxPerTxUsd;
    }

    // ------------------------------------------------------------------ internal

    function _validatePolicy(uint64 expiry, uint16 maxSlippageBps, uint128 maxPerTxUsd, uint128 dailyCapUsd)
        internal
        view
    {
        if (expiry <= block.timestamp) revert InvalidExpiry();
        if (maxSlippageBps > MAX_SLIPPAGE_BPS || maxPerTxUsd == 0 || dailyCapUsd == 0 || maxPerTxUsd > dailyCapUsd) {
            revert InvalidPolicy();
        }
    }

    function _key(address agent, uint32 epoch, address x) internal pure returns (bytes32) {
        return keccak256(abi.encode(agent, epoch, x));
    }

    function _currentWindow(Agent memory a) internal view returns (uint64 ws, uint128 spent) {
        ws = a.windowStart;
        spent = a.spentUsdInWindow;
        if (ws == 0) return (uint64(block.timestamp), 0);
        if (block.timestamp >= uint256(ws) + PERIOD) {
            uint256 elapsed = (block.timestamp - ws) / PERIOD;
            ws = uint64(uint256(ws) + elapsed * PERIOD);
            spent = 0;
        }
    }

    function _roll(Agent storage a) internal {
        (uint64 ws, uint128 spent) = _currentWindow(a);
        if (ws != a.windowStart) {
            a.windowStart = ws;
            a.spentUsdInWindow = spent;
        }
    }

    function _revoke(address agent) internal {
        Agent storage a = agents[agent];
        a.active = false;
        a.expiry = 0;
        a.windowStart = 0;
        a.spentUsdInWindow = 0;
        unchecked {
            a.epoch += 1;
        }
        emit AgentRevoked(agent, msg.sender, a.epoch);
    }


    function _prepareSwap(address tokenIn, address tokenOut, uint256 amountIn, address router)
        internal
        returns (SwapPrep memory p)
    {
        Agent storage a = agents[msg.sender];
        if (!a.active) revert NotAgent();
        if (block.timestamp >= a.expiry) revert AgentExpired();
        if (tokenIn == address(0) || tokenOut == address(0) || tokenIn == tokenOut) revert InvalidToken();
        if (amountIn == 0) revert ZeroAmount();
        if (router == address(0) || router == address(this) || router == tokenIn || router == tokenOut) {
            revert InvalidRouter();
        }

        uint32 epoch = a.epoch;
        if (!_tokenAllowed[_key(msg.sender, epoch, tokenIn)] || !_tokenAllowed[_key(msg.sender, epoch, tokenOut)]) {
            revert TokenNotAllowed();
        }
        if (!_routerAllowed[_key(msg.sender, epoch, router)]) revert RouterNotAllowed();

        p.inUsd = _usd8(tokenIn, amountIn);
        if (p.inUsd > a.maxPerTxUsd) revert ExceedsPerTxCap(p.inUsd, a.maxPerTxUsd);

        _roll(a);
        p.wouldSpend = uint256(a.spentUsdInWindow) + p.inUsd;
        if (p.wouldSpend > a.dailyCapUsd) revert ExceedsDailyCap(p.wouldSpend, a.dailyCapUsd);

        p.minOut = _minOut(tokenIn, tokenOut, amountIn, a.maxSlippageBps);
        if (p.minOut == 0) revert InvalidOracleMinOut();

        p.ethBefore = address(this).balance;
        p.inBefore = IERC20(tokenIn).balanceOf(address(this));
        p.outBefore = IERC20(tokenOut).balanceOf(address(this));
        if (p.inBefore < amountIn) revert InsufficientBalance();

        a.spentUsdInWindow = uint128(p.wouldSpend);
    }

    function _finalizeSwap(address tokenIn, address tokenOut, uint256 amountIn, SwapPrep memory p)
        internal
        view
        returns (uint256 amountOut)
    {
        if (address(this).balance < p.ethBefore) revert EthMoved();

        uint256 inAfter = IERC20(tokenIn).balanceOf(address(this));
        if (inAfter < p.inBefore && p.inBefore - inAfter > amountIn) {
            revert ExcessInputPulled(p.inBefore - inAfter, amountIn);
        }

        uint256 outAfter = IERC20(tokenOut).balanceOf(address(this));
        if (outAfter < p.outBefore + p.minOut) {
            uint256 got = outAfter > p.outBefore ? outAfter - p.outBefore : 0;
            revert SlippageExceeded(got, p.minOut);
        }
        amountOut = outAfter - p.outBefore;
    }

    function _approveRouter(address token, address router, uint256 amount) internal {
        IERC20(token).forceApprove(router, amount);
        if (permit2Enabled && PERMIT2.code.length > 0) {
            if (amount > type(uint160).max) revert AmountTooLargeForPermit2();
            IERC20(token).forceApprove(PERMIT2, amount);
            IPermit2(PERMIT2).approve(token, router, uint160(amount), uint48(block.timestamp + 2 minutes));
        }
    }

    function _clearApprovals(address token, address router) internal {
        IERC20(token).forceApprove(router, 0);
        if (permit2Enabled && PERMIT2.code.length > 0) {
            IERC20(token).forceApprove(PERMIT2, 0);
            IPermit2(PERMIT2).approve(token, router, 0, 0);
        }
    }

    function _price(address token) internal view returns (uint256 price, uint8 priceDec) {
        Feed memory f = feeds[token];
        if (f.aggregator == address(0)) revert NoFeed();
        _checkSequencer();
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            AggregatorV3Interface(f.aggregator).latestRoundData();
        if (answer <= 0 || updatedAt == 0 || answeredInRound < roundId || block.timestamp > updatedAt + f.maxStale) {
            revert StaleOrInvalidPrice();
        }
        return (uint256(answer), f.decimals);
    }

    /// @dev Audit 2026-11-23 M-01: refuse prices while the L2 sequencer is down or just restarted.
    function _checkSequencer() internal view {
        address sf = sequencerFeed;
        if (sf == address(0)) return;
        (, int256 answer, uint256 startedAt,,) = AggregatorV3Interface(sf).latestRoundData();
        if (answer != 0) revert SequencerDown();
        if (startedAt == 0 || block.timestamp - startedAt <= SEQUENCER_GRACE) revert SequencerGracePeriod();
    }

    /// @dev USD value with 8 decimals ($1 = 1e8).
    function _usd8(address token, uint256 amount) internal view returns (uint256) {
        (uint256 price, uint8 priceDec) = _price(token);
        uint8 tokenDec = IERC20Metadata(token).decimals();
        return Math.mulDiv(amount, price * 1e8, (10 ** tokenDec) * (10 ** priceDec));
    }

    function _fromUsd8(address token, uint256 usd8) internal view returns (uint256) {
        (uint256 price, uint8 priceDec) = _price(token);
        uint8 tokenDec = IERC20Metadata(token).decimals();
        return Math.mulDiv(usd8, (10 ** tokenDec) * (10 ** priceDec), price * 1e8);
    }

    function _minOut(address tokenIn, address tokenOut, uint256 amountIn, uint16 slippageBps)
        internal
        view
        returns (uint256)
    {
        if (slippageBps > BPS_DENOM) revert InvalidPolicy();
        uint256 inUsd = _usd8(tokenIn, amountIn);
        uint256 outUsd = inUsd * (uint256(BPS_DENOM) - slippageBps) / BPS_DENOM;
        return _fromUsd8(tokenOut, outUsd);
    }
}
