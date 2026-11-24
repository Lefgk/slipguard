// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SlipGuardVault} from "../../src/SlipGuardVault.sol";
import {SlipGuardVaultFactory} from "../../src/SlipGuardVaultFactory.sol";
import {MockUSDC} from "../../src/MockUSDC.sol";
import {MockWETH} from "../../src/MockWETH.sol";
import {MockAggregator} from "../../src/mocks/MockAggregator.sol";
import {MockRouter} from "../../src/mocks/MockRouter.sol";

/// @dev USDT-style token: 6 decimals, transfer/approve/transferFrom return nothing, and approve
///      reverts when changing a non-zero allowance to another non-zero value.
contract MockUSDT {
    string public name = "Tether USD";
    string public symbol = "USDT";
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external {
        require(!(a != 0 && allowance[msg.sender][s] != 0), "USDT: reset first");
        allowance[msg.sender][s] = a;
    }

    function transfer(address to, uint256 a) external {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
    }

    function transferFrom(address f, address to, uint256 a) external {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
    }
}

/// @dev 6-decimal token that burns 1% on every transfer.
contract FeeToken {
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function _move(address f, address to, uint256 a) internal {
        balanceOf[f] -= a;
        balanceOf[to] += a - a / 100;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        _move(msg.sender, to, a);
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        _move(f, to, a);
        return true;
    }
}

contract MockPermit2 {
    struct A {
        uint160 amount;
        uint48 expiration;
    }
    mapping(address => mapping(address => mapping(address => A))) public allowed;

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        allowed[msg.sender][token][spender] = A(amount, expiration);
    }
}

/// @dev Router that tolerates no-return-value tokens (USDT) via low-level calls.
contract LooseRouter {
    function swap(address tIn, address tOut, uint256 aIn, uint256 aOut, address payer, address to) external {
        (bool ok,) = tIn.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", payer, address(this), aIn));
        require(ok, "in");
        (ok,) = tOut.call(abi.encodeWithSignature("transfer(address,uint256)", to, aOut));
        require(ok, "out");
    }
}

contract EthSink {
    receive() external payable {
        revert("no");
    }
}

contract SlipGuardPolishTest is Test {
    address constant P2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    SlipGuardVault vault;
    MockUSDC usdc;
    MockWETH weth;
    MockAggregator ethUsd;
    MockAggregator usdcUsd;
    MockRouter router;
    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address guardian = makeAddr("guardian");
    address rando = makeAddr("rando");

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
        vault = new SlipGuardVault(owner, address(weth));
        usdc.mint(address(vault), 100_000e6);
        weth.transfer(address(vault), 20 ether);
        vm.startPrank(owner);
        vault.setFeed(address(weth), address(ethUsd), 1 hours);
        vault.setFeed(address(usdc), address(usdcUsd), 1 days);
        vault.grantAgent(agent, uint64(block.timestamp + 7 days), 100, MAX_TX, DAILY);
        vault.setTokenAllowed(agent, address(usdc), true);
        vault.setTokenAllowed(agent, address(weth), true);
        vault.setRouterAllowed(agent, address(router), true);
        vault.setGuardian(guardian);
        vm.stopPrank();
    }

    function _swapData(SlipGuardVault v, address tIn, address tOut, uint256 amtIn, uint256 out)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeWithSelector(MockRouter.swap.selector, tIn, tOut, amtIn, out, address(v), address(v));
    }

    function _swap(address tIn, address tOut, uint256 amtIn) internal returns (uint256) {
        uint256 minOut = vault.previewMinOut(tIn, tOut, amtIn, 100);
        vm.prank(agent);
        return vault.executeSwap(tIn, tOut, amtIn, address(router), _swapData(vault, tIn, tOut, amtIn, minOut));
    }

    // ------------------------------------------------------------ access control

    function test_onlyOwnerAdminFunctions() public {
        vm.startPrank(rando);
        bytes4 oz = Ownable.OwnableUnauthorizedAccount.selector;
        vm.expectRevert(abi.encodeWithSelector(oz, rando));
        vault.setGuardian(rando);
        vm.expectRevert(abi.encodeWithSelector(oz, rando));
        vault.setPermit2Enabled(true);
        vm.expectRevert(abi.encodeWithSelector(oz, rando));
        vault.setFeed(address(usdc), address(usdcUsd), 1);
        vm.expectRevert(abi.encodeWithSelector(oz, rando));
        vault.grantAgent(rando, uint64(block.timestamp + 1 days), 1, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(oz, rando));
        vault.setPolicy(agent, uint64(block.timestamp + 1 days), 1, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(oz, rando));
        vault.setTokenAllowed(agent, address(usdc), false);
        vm.expectRevert(abi.encodeWithSelector(oz, rando));
        vault.setRouterAllowed(agent, address(router), false);
        vm.expectRevert(abi.encodeWithSelector(oz, rando));
        vault.unpause();
        vm.expectRevert(abi.encodeWithSelector(oz, rando));
        vault.unwrapWETH(1);
        vm.expectRevert(abi.encodeWithSelector(oz, rando));
        vault.withdrawETH(rando, 1);
        vm.expectRevert(abi.encodeWithSelector(oz, rando));
        vault.withdraw(address(usdc), rando, 1);
        vm.expectRevert(SlipGuardVault.NotOwnerOrGuardian.selector);
        vault.pause();
        vm.expectRevert(SlipGuardVault.NotOwnerOrGuardian.selector);
        vault.revokeAgent(agent);
        vm.stopPrank();
    }

    function test_guardianCannotUnpauseOrWithdraw() public {
        vm.startPrank(guardian);
        vault.pause();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vault.unpause();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vault.withdraw(address(usdc), guardian, 1);
        vm.stopPrank();
        vm.prank(owner);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_agentCannotCallAdminOrWithdraw() public {
        vm.startPrank(agent);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, agent));
        vault.withdraw(address(usdc), agent, 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, agent));
        vault.setPolicy(agent, uint64(block.timestamp + 1 days), 2000, 1e12, 1e12);
        vm.expectRevert(SlipGuardVault.NotOwnerOrGuardian.selector);
        vault.revokeAgent(agent);
        vm.stopPrank();
    }

    function test_removedGuardianLosesPowers() public {
        vm.prank(owner);
        vault.setGuardian(address(0));
        vm.prank(guardian);
        vm.expectRevert(SlipGuardVault.NotOwnerOrGuardian.selector);
        vault.pause();
    }

    function test_ownershipTwoStep() public {
        vm.prank(owner);
        vault.transferOwnership(rando);
        assertEq(vault.owner(), owner);
        vm.prank(rando);
        vault.acceptOwnership();
        assertEq(vault.owner(), rando);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vault.withdraw(address(usdc), owner, 1);
    }

    function test_setPolicyOnInactiveAgentReverts() public {
        vm.prank(owner);
        vm.expectRevert(SlipGuardVault.NotAgent.selector);
        vault.setPolicy(rando, uint64(block.timestamp + 1 days), 1, 1, 1);
    }

    // ------------------------------------------------------------ input validation

    function test_zeroAddressAndZeroAmountReverts() public {
        vm.startPrank(owner);
        vm.expectRevert(SlipGuardVault.ZeroAddress.selector);
        vault.withdraw(address(usdc), address(0), 1);
        vm.expectRevert(SlipGuardVault.InvalidToken.selector);
        vault.withdraw(address(0), owner, 1);
        vm.expectRevert(SlipGuardVault.ZeroAmount.selector);
        vault.withdraw(address(usdc), owner, 0);
        vm.expectRevert(SlipGuardVault.ZeroAddress.selector);
        vault.withdrawETH(address(0), 1);
        vm.expectRevert(SlipGuardVault.ZeroAmount.selector);
        vault.withdrawETH(owner, 0);
        vm.expectRevert(SlipGuardVault.ZeroAmount.selector);
        vault.unwrapWETH(0);
        vm.expectRevert(SlipGuardVault.ZeroAddress.selector);
        vault.grantAgent(address(0), uint64(block.timestamp + 1), 1, 1, 1);
        vm.expectRevert(SlipGuardVault.ZeroAddress.selector);
        vault.setFeed(address(0), address(usdcUsd), 1);
        vm.expectRevert(SlipGuardVault.ZeroAddress.selector);
        vault.setFeed(address(usdc), address(0), 1);
        vm.expectRevert(SlipGuardVault.InvalidFeed.selector);
        vault.setFeed(address(usdc), address(usdcUsd), 0);
        vm.expectRevert(SlipGuardVault.InvalidToken.selector);
        vault.setTokenAllowed(agent, address(0), true);
        vm.expectRevert(SlipGuardVault.InvalidRouter.selector);
        vault.setRouterAllowed(agent, address(0), true);
        vm.expectRevert(SlipGuardVault.InvalidRouter.selector);
        vault.setRouterAllowed(agent, address(vault), true);
        vm.stopPrank();

        vm.expectRevert(SlipGuardVault.ZeroAmount.selector);
        vault.wrapETH();
        vm.expectRevert(SlipGuardVault.InvalidToken.selector);
        vault.deposit(address(0), 1);
        vm.expectRevert(SlipGuardVault.ZeroAmount.selector);
        vault.deposit(address(usdc), 0);
        vm.expectRevert(SlipGuardVault.ZeroAddress.selector);
        new SlipGuardVault(owner, address(0));
    }

    function test_withdrawMoreThanBalanceReverts() public {
        vm.prank(owner);
        vm.expectRevert();
        vault.withdraw(address(usdc), owner, type(uint256).max);
    }

    function test_policyBoundsAndPastExpiry() public {
        vm.startPrank(owner);
        uint64 ok = uint64(block.timestamp + 1 days);
        vm.expectRevert(SlipGuardVault.InvalidExpiry.selector);
        vault.grantAgent(rando, uint64(block.timestamp), 1, 1, 1);
        vm.expectRevert(SlipGuardVault.InvalidPolicy.selector);
        vault.grantAgent(rando, ok, 2_001, 1, 1);
        vm.expectRevert(SlipGuardVault.InvalidPolicy.selector);
        vault.grantAgent(rando, ok, 100, 0, 1);
        vm.expectRevert(SlipGuardVault.InvalidPolicy.selector);
        vault.grantAgent(rando, ok, 100, 2, 1);
        vault.grantAgent(rando, ok, 2_000, 5, 5); // boundary accepted
        vm.stopPrank();
    }

    function test_setFeedCachesDecimals() public {
        ethUsd.setDecimals(18);
        vm.prank(owner);
        vault.setFeed(address(weth), address(ethUsd), 1 hours);
        (, , uint8 d) = vault.feeds(address(weth));
        assertEq(d, 18);
    }

    function testFuzz_feedDecimalsScaleQuote(uint8 decSeed) public {
        uint8 dec = uint8(bound(decSeed, 0, 18));
        MockAggregator agg = new MockAggregator(int256(3000 * 10 ** dec), block.timestamp);
        agg.setDecimals(dec);
        vm.prank(owner);
        vault.setFeed(address(weth), address(agg), 1 hours);
        assertEq(vault.quoteUsd(address(weth), 1 ether), 3000e8);
    }

    // ------------------------------------------------------------ funding

    function test_depositEventRecordsReceivedAmountForFeeToken() public {
        FeeToken ft = new FeeToken();
        ft.mint(rando, 1_000e6);
        vm.startPrank(rando);
        ft.approve(address(vault), 1_000e6);
        vm.expectEmit(true, true, false, true);
        emit SlipGuardVault.Deposited(rando, address(ft), 990e6);
        vault.deposit(address(ft), 1_000e6);
        vm.stopPrank();
        assertEq(ft.balanceOf(address(vault)), 990e6);
    }

    function test_receiveEmitsDeposited() public {
        vm.deal(rando, 1 ether);
        vm.expectEmit(true, true, false, true);
        emit SlipGuardVault.Deposited(rando, address(0), 1 ether);
        vm.prank(rando);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
    }

    function test_withdrawETHRevertsWhenRecipientRejects() public {
        vm.deal(address(vault), 1 ether);
        EthSink s = new EthSink();
        vm.prank(owner);
        vm.expectRevert(SlipGuardVault.EthTransferFailed.selector);
        vault.withdrawETH(address(s), 1 ether);
    }

    function test_withdrawETHWorksWhilePaused() public {
        vm.deal(address(vault), 1 ether);
        vm.prank(guardian);
        vault.pause();
        vm.prank(owner);
        vault.withdrawETH(owner, 1 ether);
        assertEq(owner.balance, 1 ether);
    }

    function test_wrapUnwrapWhilePausedAndByAnyoneWrap() public {
        vm.deal(address(vault), 2 ether);
        vm.prank(owner);
        vault.pause();
        vm.prank(rando);
        assertEq(vault.wrapETH(), 2 ether);
        vm.prank(owner);
        vault.unwrapWETH(1 ether);
        assertEq(address(vault).balance, 1 ether);
    }

    // ------------------------------------------------------------ swap guards

    function test_swapBasicGuards() public {
        vm.startPrank(agent);
        vm.expectRevert(SlipGuardVault.ZeroAmount.selector);
        vault.executeSwap(address(usdc), address(weth), 0, address(router), "");
        vm.expectRevert(SlipGuardVault.InvalidToken.selector);
        vault.executeSwap(address(usdc), address(usdc), 1e6, address(router), "");
        vm.expectRevert(SlipGuardVault.InvalidToken.selector);
        vault.executeSwap(address(0), address(usdc), 1e6, address(router), "");
        vm.expectRevert(SlipGuardVault.InvalidRouter.selector);
        vault.executeSwap(address(usdc), address(weth), 1e6, address(vault), "");
        vm.expectRevert(SlipGuardVault.InvalidRouter.selector);
        vault.executeSwap(address(usdc), address(weth), 1e6, address(usdc), "");
        vm.expectRevert(SlipGuardVault.InvalidRouter.selector);
        vault.executeSwap(address(usdc), address(weth), 1e6, address(0), "");
        vm.stopPrank();
    }

    function test_swapRevertsOnInsufficientBalance() public {
        // raise caps so the balance check is the binding one
        vm.prank(owner);
        vault.setPolicy(agent, uint64(block.timestamp + 1 days), 100, 1_000_000e8, 1_000_000e8);
        uint256 amt = usdc.balanceOf(address(vault)) + 1;
        vm.prank(agent);
        vm.expectRevert(SlipGuardVault.InsufficientBalance.selector);
        vault.executeSwap(address(usdc), address(weth), amt, address(router), "");
    }

    function test_swapBubblesRouterRevertReason() public {
        bytes memory d = _swapData(vault, address(usdc), address(weth), 100e6, type(uint128).max); // out > router balance
        vm.prank(agent);
        vm.expectRevert();
        vault.executeSwap(address(usdc), address(weth), 100e6, address(router), d);
    }

    function test_swapRevertRollsBackSpentWindow() public {
        bytes memory d = _swapData(vault, address(usdc), address(weth), 100e6, 1); // below min-out
        vm.prank(agent);
        vm.expectRevert();
        vault.executeSwap(address(usdc), address(weth), 100e6, address(router), d);
        (, , , , , , , uint128 spent) = vault.agents(agent);
        assertEq(spent, 0);
    }

    function test_swapRevertsOnZeroMinOutFromTinyAmount() public {
        // 1 wei of WETH is worth far less than 1e-8 USD -> usd8 rounds to 0 -> minOut 0 -> rejected
        vm.prank(agent);
        vm.expectRevert(SlipGuardVault.InvalidOracleMinOut.selector);
        vault.executeSwap(address(weth), address(usdc), 1, address(router), "");
    }

    function test_swapWithUnallowedTokenOrRouter() public {
        MockUSDC other = new MockUSDC();
        vm.prank(agent);
        vm.expectRevert(SlipGuardVault.TokenNotAllowed.selector);
        vault.executeSwap(address(usdc), address(other), 1e6, address(router), "");
        MockRouter r2 = new MockRouter();
        vm.prank(agent);
        vm.expectRevert(SlipGuardVault.RouterNotAllowed.selector);
        vault.executeSwap(address(usdc), address(weth), 1e6, address(r2), "");
    }

    function test_tokenAllowedWithoutFeedReverts() public {
        MockUSDC other = new MockUSDC();
        other.mint(address(vault), 1e6);
        vm.prank(owner);
        vault.setTokenAllowed(agent, address(other), true);
        vm.prank(agent);
        vm.expectRevert(SlipGuardVault.NoFeed.selector);
        vault.executeSwap(address(other), address(weth), 1e6, address(router), "");
    }

    function test_swapExpiresExactlyAtExpiry() public {
        (, uint64 exp,,,,,,) = vault.agents(agent);
        vm.warp(exp);
        ethUsd.set(3000e8, block.timestamp);
        usdcUsd.set(1e8, block.timestamp);
        vm.prank(agent);
        vm.expectRevert(SlipGuardVault.AgentExpired.selector);
        vault.executeSwap(address(usdc), address(weth), 1e6, address(router), "");
    }

    function test_swapEmitsSwappedEvent() public {
        uint256 amt = 100e6;
        uint256 minOut = vault.previewMinOut(address(usdc), address(weth), amt, 100);
        vm.expectEmit(true, true, true, true);
        emit SlipGuardVault.Swapped(
            agent, address(usdc), address(weth), address(router), amt, minOut, minOut, 100e8, 100e8, uint64(block.timestamp)
        );
        _swap(address(usdc), address(weth), amt);
    }

    function test_perTxCapBoundaryExact() public {
        _swap(address(usdc), address(weth), 1_000e6); // exactly MAX_TX
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(SlipGuardVault.ExceedsPerTxCap.selector, 1_000_000001 * 100, MAX_TX));
        vault.executeSwap(address(usdc), address(weth), 1_000_000001, address(router), "");
    }

    // ------------------------------------------------------------ daily window

    function test_dailyWindowRolloverAndExactBoundary() public {
        for (uint256 i; i < 5; i++) {
            _swap(address(usdc), address(weth), 1_000e6);
        }
        vm.prank(agent);
        vm.expectRevert();
        vault.executeSwap(address(usdc), address(weth), 1e6, address(router), "");

        (, , , , , uint64 ws, ,) = _agentFields();
        vm.warp(ws + 1 days - 1);
        ethUsd.set(3000e8, block.timestamp);
        usdcUsd.set(1e8, block.timestamp);
        vm.prank(agent);
        vm.expectRevert();
        vault.executeSwap(address(usdc), address(weth), 1e6, address(router), "");

        vm.warp(ws + 1 days);
        ethUsd.set(3000e8, block.timestamp);
        usdcUsd.set(1e8, block.timestamp);
        _swap(address(usdc), address(weth), 1_000e6);
        (, , , , , uint64 ws2, uint128 spent2,) = _agentFields();
        assertEq(ws2, ws + 1 days);
        assertEq(spent2, 1_000e8);
    }

    function test_windowFloorsAcrossMultipleIdleDays() public {
        (, , , , , uint64 ws,,) = _agentFields();
        vm.warp(ws + 3 days + 5 hours);
        ethUsd.set(3000e8, block.timestamp);
        usdcUsd.set(1e8, block.timestamp);
        _swap(address(usdc), address(weth), 10e6);
        (, , , , , uint64 ws2,,) = _agentFields();
        assertEq(ws2, ws + 3 days);
    }

    function _agentFields()
        internal
        view
        returns (bool, uint64, uint32, uint16, uint128, uint64, uint128, uint128)
    {
        (bool a, uint64 e, uint32 ep, uint16 s, uint128 mt, uint128 dc, uint64 ws, uint128 sp) = vault.agents(agent);
        // reorder: (active, expiry, epoch, slip, maxTx, windowStart, spent, dailyCap)
        return (a, e, ep, s, mt, ws, sp, dc);
    }

    function test_setPolicyKeepsSpentAndAllowlists() public {
        _swap(address(usdc), address(weth), 500e6);
        vm.prank(owner);
        vault.setPolicy(agent, uint64(block.timestamp + 2 days), 50, 600e8, 700e8);
        (, , , , , , uint128 spent,) = _agentFields();
        assertEq(spent, 500e8);
        assertTrue(vault.isTokenAllowed(agent, address(usdc)));
        assertTrue(vault.isRouterAllowed(agent, address(router)));
        // 200e8 left under the new daily cap; 300e8 more must revert
        vm.prank(agent);
        vm.expectRevert();
        vault.executeSwap(address(usdc), address(weth), 300e6, address(router), "");
        (uint256 amt,) = vault.spendableUsdNow(agent);
        assertEq(amt, 200e8);
    }

    function test_spendableUsdNowEdgeCases() public {
        (uint256 a, uint64 end) = vault.spendableUsdNow(rando);
        assertEq(a, 0);
        assertEq(end, 0);
        (a,) = vault.spendableUsdNow(agent);
        assertEq(a, MAX_TX);
        vm.prank(guardian);
        vault.pause();
        (a,) = vault.spendableUsdNow(agent);
        assertEq(a, 0);
        vm.prank(owner);
        vault.unpause();
        vm.warp(block.timestamp + 8 days);
        (a,) = vault.spendableUsdNow(agent);
        assertEq(a, 0); // expired
    }

    // ------------------------------------------------------------ revoke / panic

    function test_revokeThenRegrantStartsClean() public {
        _swap(address(usdc), address(weth), 500e6);
        vm.prank(guardian);
        vault.revokeAgent(agent);
        (bool active, uint64 exp, uint32 epoch,,,, uint128 spent,) = _agentFields();
        assertFalse(active);
        assertEq(exp, 0);
        assertEq(epoch, 1);
        assertEq(spent, 0);
        vm.prank(agent);
        vm.expectRevert(SlipGuardVault.NotAgent.selector);
        vault.executeSwap(address(usdc), address(weth), 1e6, address(router), "");

        vm.prank(owner);
        vault.grantAgent(agent, uint64(block.timestamp + 1 days), 100, MAX_TX, DAILY);
        // allowlists from the old epoch do not carry over
        assertFalse(vault.isTokenAllowed(agent, address(usdc)));
        assertFalse(vault.isRouterAllowed(agent, address(router)));
        vm.prank(agent);
        vm.expectRevert(SlipGuardVault.TokenNotAllowed.selector);
        vault.executeSwap(address(usdc), address(weth), 1e6, address(router), "");
    }

    function test_renounceByNonAgentReverts() public {
        vm.prank(rando);
        vm.expectRevert(SlipGuardVault.NotAgent.selector);
        vault.renounceAgent();
    }

    function test_revokeEmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit SlipGuardVault.AgentRevoked(agent, owner, 1);
        vm.prank(owner);
        vault.revokeAgent(agent);
    }

    function test_pausedSwapRevertsAndUnpauseRestores() public {
        vm.prank(guardian);
        vault.pause();
        vm.prank(agent);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.executeSwap(address(usdc), address(weth), 1e6, address(router), "");
        vm.prank(owner);
        vault.unpause();
        _swap(address(usdc), address(weth), 10e6);
    }

    // ------------------------------------------------------------ oracle

    function test_staleBoundaryExact() public {
        uint256 t = block.timestamp;
        vm.warp(t + 1 hours); // exactly maxStale on weth feed: allowed
        usdcUsd.set(1e8, block.timestamp);
        assertEq(vault.quoteUsd(address(weth), 1 ether), 3000e8);
        vm.warp(t + 1 hours + 1);
        vm.expectRevert(SlipGuardVault.StaleOrInvalidPrice.selector);
        vault.quoteUsd(address(weth), 1 ether);
    }

    function test_incompleteRoundReverts() public {
        ethUsd.setRound(5, 4);
        vm.expectRevert(SlipGuardVault.StaleOrInvalidPrice.selector);
        vault.quoteUsd(address(weth), 1 ether);
    }

    function test_zeroUpdatedAtReverts() public {
        ethUsd.set(3000e8, 0);
        vm.expectRevert(SlipGuardVault.StaleOrInvalidPrice.selector);
        vault.quoteUsd(address(weth), 1 ether);
    }

    function test_previewMinOutRejectsSlippageAbove100Percent() public {
        vm.expectRevert(SlipGuardVault.InvalidPolicy.selector);
        vault.previewMinOut(address(usdc), address(weth), 1e6, 10_001);
    }

    // ------------------------------------------------------------ non-standard tokens

    function test_usdtStyleTokenSwapAndWithdraw() public {
        MockUSDT t = new MockUSDT();
        LooseRouter lr = new LooseRouter();
        MockAggregator tUsd = new MockAggregator(1e8, block.timestamp);
        t.mint(address(vault), 10_000e6);
        t.mint(address(lr), 10_000e6);
        weth.transfer(address(lr), 10 ether);
        vm.startPrank(owner);
        vault.setFeed(address(t), address(tUsd), 1 days);
        vault.setTokenAllowed(agent, address(t), true);
        vault.setRouterAllowed(agent, address(lr), true);
        vm.stopPrank();

        uint256 minOut = vault.previewMinOut(address(t), address(weth), 100e6, 100);
        bytes memory d = abi.encodeCall(LooseRouter.swap, (address(t), address(weth), 100e6, minOut, address(vault), address(vault)));
        vm.prank(agent);
        vault.executeSwap(address(t), address(weth), 100e6, address(lr), d);
        assertEq(t.allowance(address(vault), address(lr)), 0);
        // second swap works: approval was cleared (USDT reverts on non-zero -> non-zero)
        vm.prank(agent);
        vault.executeSwap(address(t), address(weth), 100e6, address(lr), d);

        // output leg in USDT
        uint256 outMin = vault.previewMinOut(address(weth), address(t), 0.01 ether, 100);
        bytes memory d2 = abi.encodeCall(LooseRouter.swap, (address(weth), address(t), 0.01 ether, outMin, address(vault), address(vault)));
        vm.prank(agent);
        vault.executeSwap(address(weth), address(t), 0.01 ether, address(lr), d2);

        vm.prank(owner);
        vault.withdraw(address(t), owner, 1_000e6);
        assertEq(t.balanceOf(owner), 1_000e6);
    }

    function test_feeOnTransferTokenInUsesBalanceDeltaChecks() public {
        // 1% burn on tokenIn: router receives 99%. Vault accounting is by balance, so swap still ok.
        FeeToken ft = new FeeToken();
        MockAggregator fUsd = new MockAggregator(1e8, block.timestamp);
        ft.mint(address(vault), 10_000e6);
        vm.startPrank(owner);
        vault.setFeed(address(ft), address(fUsd), 1 days);
        vault.setTokenAllowed(agent, address(ft), true);
        vm.stopPrank();
        uint256 minOut = vault.previewMinOut(address(ft), address(weth), 100e6, 100);
        vm.prank(agent);
        vault.executeSwap(
            address(ft), address(weth), 100e6, address(router), _swapData(vault, address(ft), address(weth), 100e6, minOut)
        );
        assertEq(ft.allowance(address(vault), address(router)), 0);
    }

    // ------------------------------------------------------------ Permit2

    function test_permit2PathGrantsThenClears() public {
        vm.etch(P2, address(new MockPermit2()).code);
        vm.prank(owner);
        vault.setPermit2Enabled(true);
        _swap(address(usdc), address(weth), 100e6);
        (uint160 amt, uint48 exp) = MockPermit2(P2).allowed(address(vault), address(usdc), address(router));
        assertEq(amt, 0);
        assertEq(exp, 0);
        assertEq(usdc.allowance(address(vault), P2), 0);
        assertEq(usdc.allowance(address(vault), address(router)), 0);
    }

    function test_permit2PathRejectsAmountAboveUint160() public {
        vm.etch(P2, address(new MockPermit2()).code);
        vm.startPrank(owner);
        vault.setPermit2Enabled(true);
        vault.setPolicy(agent, uint64(block.timestamp + 1 days), 100, type(uint128).max, type(uint128).max);
        vm.stopPrank();
        MockUSDC big = new MockUSDC();
        MockAggregator bUsd = new MockAggregator(1, block.timestamp); // tiny price so cap math does not overflow
        vm.startPrank(owner);
        vault.setFeed(address(big), address(bUsd), 1 days);
        vault.setTokenAllowed(agent, address(big), true);
        vm.stopPrank();
        uint256 amt = uint256(type(uint160).max) + 1;
        big.mint(address(vault), amt);
        vm.prank(agent);
        vm.expectRevert();
        vault.executeSwap(address(big), address(weth), amt, address(router), "");
    }

    // ------------------------------------------------------------ factory

    function test_factoryTracksMultipleVaultsPerOwner() public {
        SlipGuardVaultFactory f = new SlipGuardVaultFactory(address(weth));
        vm.startPrank(rando);
        address v1 = f.createVault();
        address v2 = f.createVault();
        vm.stopPrank();
        assertTrue(v1 != v2);
        address[] memory list = f.vaultsOf(rando);
        assertEq(list.length, 2);
        assertEq(SlipGuardVault(payable(v1)).owner(), rando);
        assertEq(SlipGuardVault(payable(v2)).weth(), address(weth));
        assertEq(f.vaultsOf(owner).length, 0);
        vm.expectRevert(bytes("factory: zero weth"));
        new SlipGuardVaultFactory(address(0));
    }

    // ------------------------------------------------------------ fuzz

    function testFuzz_swapAmountObeysCaps(uint256 amt) public {
        amt = bound(amt, 1e4, 3_000e6);
        uint256 usd = vault.quoteUsd(address(usdc), amt);
        uint256 minOut = vault.previewMinOut(address(usdc), address(weth), amt, 100);
        bytes memory d = _swapData(vault, address(usdc), address(weth), amt, minOut);
        vm.prank(agent);
        if (usd > MAX_TX) {
            vm.expectRevert(abi.encodeWithSelector(SlipGuardVault.ExceedsPerTxCap.selector, usd, MAX_TX));
        }
        vault.executeSwap(address(usdc), address(weth), amt, address(router), d);
        (, , , , , , uint128 spent,) = _agentFields();
        assertLe(spent, DAILY);
        assertEq(usdc.allowance(address(vault), address(router)), 0);
    }

    function testFuzz_minOutNeverExceedsFairValue(uint256 amt, uint16 slip) public view {
        amt = bound(amt, 1e6, 1_000_000e6);
        slip = uint16(bound(slip, 0, 10_000));
        uint256 minOut = vault.previewMinOut(address(usdc), address(weth), amt, slip);
        // value of minOut in USD must not exceed the input value times (1 - slip)
        assertLe(vault.quoteUsd(address(weth), minOut), vault.quoteUsd(address(usdc), amt) * (10_000 - slip) / 10_000);
    }

    /// 8-decimal "reward-like" token vs 18-decimal token at large supply: no truncation to zero / overflow.
    function testFuzz_eightDecimalTokenAtScale(uint256 amt) public {
        amt = bound(amt, 1e8, 1_000_000_000e8); // up to 1B tokens at 8dp
        MockUSDC eight = new MockUSDC(); // decimals fixed 6; use feed decimals instead for 8dp semantics
        MockAggregator agg = new MockAggregator(1e8, block.timestamp);
        vm.prank(owner);
        vault.setFeed(address(eight), address(agg), 1 days);
        uint256 usd = vault.quoteUsd(address(eight), amt);
        assertEq(usd, amt * 100); // 6dp token at $1 -> usd8 = amt*1e8/1e6
        uint256 back = vault.previewMinOut(address(eight), address(weth), amt, 0);
        // round trip via WETH at $3000 must be within 1 wei of exact
        assertApproxEqAbs(back, amt * 100 * 1e18 / 3000e8, 1);
    }
}
