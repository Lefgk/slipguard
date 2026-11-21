# SlipGuard — spec (prototype, 22 Nov 2026)

Source: overnight agent-DeFi research, idea 1 in `agents-trading.md`. Sibling of Agent Spend Controls.

**Problem.** An AI agent that can swap will get sandwiched, or drain the wallet if its key leaks. Hosted routers and off-chain price-impact settings only help if the agent actually uses them.

**Users.** Builders running a trading or ops agent who want a personal, self-custodial policy vault on Ethereum and Base.

**Scope (v0, after an audit and Lef's OK).** One vault per owner (EOA or Safe). The owner deposits USDC or WETH; ETH can be wrapped to WETH. Per agent: token and router allowlists, `maxSlippageBps` vs Chainlink (fail closed if stale or missing), `maxPerTx` and `dailyCap` in USD (8 decimals, $1 = 1e8), expiry, pause and revoke. `executeSwap` uses only vault funds, never pulls from the owner's wallet, never sends ETH, and requires the vault's `tokenOut` balance delta to meet the oracle min-out, so output stays in the vault. Suggested routers, verified on a fork: Uniswap Universal Router (current and 2.1.2), SwapRouter02, 1inch V6, 0x Exchange Proxy and Settler. Permit2 is opt-in (needed for Universal Router). The dapp can create, fund, grant, tighten, pause and view swaps, with a “Not deployed yet” state. Out: other chains, raw-ETH swaps, a Safe module, fees, custom routing.

**Choices for Lef to review.**
1. Both caps are in USD (8 decimals). The daily window is a fixed 24h period.
2. Owner cannot set slippage above 20%.
3. Standalone Ownable2Step vault, optional guardian (pause/revoke only). No fee.
4. Prototype, not audited. Ethereum mainnet and Base only.

**Edge.** Same mental model as Spend Controls — grant, cap, allowlist, pause, revoke — with on-chain min-out from the vault's own balances, usable with any allowlisted router.
