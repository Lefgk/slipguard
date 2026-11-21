// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Test-only swap target. Can pay the requested out, underpay, or send output elsewhere.
contract MockRouter {
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address payer, address recipient)
        external
    {
        IERC20(tokenIn).transferFrom(payer, address(this), amountIn);
        require(IERC20(tokenOut).transfer(recipient, amountOut), "router: out");
    }

    /// @dev Pulls more than amountIn if the vault left a larger approval.
    function overpull(address tokenIn, address payer, uint256 amount) external {
        IERC20(tokenIn).transferFrom(payer, address(this), amount);
    }

    function pullEth() external {
        payable(msg.sender).transfer(0); // no-op: cannot pull ETH from the vault without the vault sending it
    }

    function tryWithdraw(address vault, address token, address to, uint256 amount) external {
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok,) = vault.call(abi.encodeWithSignature("withdraw(address,address,uint256)", token, to, amount));
        require(ok, "withdraw failed");
    }
}
