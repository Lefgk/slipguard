# SlipGuard

On-chain swap limits for AI agents on Ethereum. The owner funds a personal vault and grants an agent capped, time-limited swap rights: a **token allowlist**, a **router allowlist**, **max slippage vs Chainlink**, a **per-tx and daily USD cap**, and an **expiry**. The owner can **pause** everything or **revoke** one agent instantly. `executeSwap` uses only vault funds; min-out is enforced from the vault's own balance delta, so output stays in the vault.

> Prototype, **not audited**. It targets **Ethereum mainnet (1)** and **Base (8453)**, plus local anvil (31337) for development. The deploy scripts refuse any other chain and **refuse to broadcast on 1/8453 unless `CONFIRM_MAINNET=yes`**. Nothing has been deployed.

See [SPEC.md](SPEC.md) for the problem, choices and scope, and [DEPLOY.md](DEPLOY.md) for the full deploy runbook.

## Layout
| Path | What |
|---|---|
| `src/SlipGuardVault.sol` | The vault: policy, allowlists, Chainlink min-out, pause, revoke, `executeSwap()` |
| `src/SlipGuardVaultFactory.sol` | Deploys one vault per owner and indexes them (`vaultsOf`) |
| `src/Addresses.sol` | Canonical USDC, WETH, router and feed addresses for Ethereum and Base |
| `src/MockUSDC.sol`, `src/MockWETH.sol` | Test/local tokens, used on anvil only |
| `test/` | Unit, fuzz and invariant tests (Foundry) |
| `test/fork/` | Fork tests: real USDC/WETH swap through Uniswap + Chainlink, plus `Deploy.s.sol` |
| `script/Deploy.s.sol`, `script/DeployConfig.sol` | Deploy script and per-chain config |
| `script/deploy.sh`, `script/verify.sh`, `script/deploy-anvil.sh` | Dry-run/broadcast wrapper, Etherscan v2 verify, local deploy |
| `script/dry-run-fork.sh`, `script/write-web-config.sh` | Anvil-fork dry run (port 8624) and dapp-config writer |
| `web/` | Vite + React + wagmi/viem dapp (Ethereum, Base and anvil) |
| `web/src/deployments.json` | Per-chain factory/USDC/WETH addresses written by a successful deploy |
| `docs/slither-report.txt` | Static-analysis output (if slither was run) |
| `Makefile` | One-command test, dapp build, dry-run and deploy targets |

## Contract model
- `grantAgent(agent, expiry, maxSlippageBps, maxPerTxUsd, dailyCapUsd)` plus `setTokenAllowed` / `setRouterAllowed` are owner only. USD amounts use 8 decimals (`$1 = 1e8`). Daily caps use fixed 24h windows.
- `executeSwap(tokenIn, tokenOut, amountIn, router, data)` is called by the agent. It checks the agent is active and not expired, the vault isn't paused, both tokens and the router are allowlisted, both USD caps hold, and the Chainlink min-out is met from the vault's `tokenOut` balance delta. Approvals are set for `amountIn` only and cleared afterwards. The call is `nonReentrant` and never sends ETH.
- If the agent points the router's `recipient` anywhere but the vault, the min-out check fails and the whole swap reverts.
- `revokeAgent(agent)` (owner or guardian) bumps the agent's epoch, so all of its allowlist entries die at once.
- `pause()` can be called by the owner or guardian, and `unpause()` by the owner only. `withdraw()` / `withdrawETH()` are owner only and work while paused.
- `setPermit2Enabled(true)` is required before Universal Router swaps (Permit2 at `0x000000000022D473030F116dDEE9F6B43aC78BA3`). SwapRouter02 works without it.
- Feeds are set with `setFeed(token, aggregator, maxStale)`. Missing or stale feeds fail closed.
- Ownership uses `Ownable2Step`, so a Safe can be the owner.

## Run the dapp

```bash
cd web
npm install
# optional: cp .env.example .env   # only to override RPCs or factory addresses
npm run dev      # http://localhost:5173
npm run build    # production build
```

The dapp is Vite + React + wagmi/viem, on Ethereum mainnet and Base (and local anvil). Contract addresses come from `web/src/deployments.json`, with optional `VITE_FACTORY_*` overrides in `web/.env`. When the factory address for the selected chain is empty, the page shows a clear **Not deployed yet** state and disables create-vault.

Connect a wallet, switch network, then: create or pick a vault, deposit USDC or WETH (or wrap ETH), set Chainlink feeds, grant an agent (slippage, USD caps, tokens, routers, expiry), tighten the policy, inspect spendable USD and recent `Swapped` events, pause the vault, or revoke an agent.

## Tests

Needs Foundry (`forge` / `anvil`; this repo expects `~/.foundry/bin` on `PATH`) and Node 20+.

```bash
forge build
forge test              # unit, fuzz, invariant, and anvil deploy-script tests; fork tests skip without a fork
make dry-run-mainnet    # Deploy.s.sol dry-run + CONFIRM_MAINNET guard, on an anvil mainnet fork at port 8624
```

Fork tests (real Circle USDC, Uniswap SwapRouter02, Chainlink ETH/USD and USDC/USD, plus the deploy-script fork tests):

```bash
anvil --port 8624 --fork-url https://ethereum-rpc.publicnode.com   # Ethereum fork
make test-fork-mainnet
# Base, using Foundry's own fork (no extra anvil):
make test-fork-base
```

This worker uses **port 8624 only**.

## Deploy to Ethereum or Base (not done: needs Lef's wallet and OK)

Once the wallet is set (Foundry keystore account, keystore file, or `DEPLOYER_KEY` in a git-ignored `.env`):

```bash
cp .env.example .env && set -a && source .env && set +a
make dry-run-mainnet                 # local anvil fork on port 8624; sends nothing
CONFIRM_MAINNET=yes make deploy-mainnet
CONFIRM_MAINNET=yes make deploy-base
```

A successful broadcast writes the factory address into `web/src/deployments.json` and, if `ETHERSCAN_API_KEY` is set, verifies via the Etherscan v2 API. See [DEPLOY.md](DEPLOY.md) for signer options and `./script/verify.sh`.

- `deploy.sh` and `Deploy.s.sol` both print the chain. Each refuses to broadcast on 1 or 8453 without `CONFIRM_MAINNET=yes`, so the guard holds even if someone calls `forge script` directly.
- Never commit `.env`, keys, or `broadcast/`.

## Local end-to-end (anvil, no keys)

```bash
anvil --port 8624                       # terminal 1 (chain 31337)
ANVIL_RPC=http://127.0.0.1:8624 ./script/deploy-anvil.sh
cd web && npm install && npm run dev
```

The anvil deploy uses anvil's unlocked dev accounts, so no private key is stored anywhere.

## Regenerate ABIs
`forge build && node tools/gen-abi.mjs` writes `web/src/abi.ts`.

## Contact

Support and questions: [lg.playstudio@gmail.com](mailto:lg.playstudio@gmail.com)
