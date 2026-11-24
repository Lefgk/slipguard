import { useMemo, useState } from "react";
import { useAccount, useBalance, useChainId, usePublicClient, useReadContract } from "wagmi";
import { useQuery } from "@tanstack/react-query";
import { erc20Abi, formatUnits, isAddress, parseUnits, type Address } from "viem";
import { slipGuardVaultAbi, slipGuardVaultFactoryAbi } from "./abi";
import { deployments, known } from "./config";
import { Addr, Empty, Hint, Loading, Shell, short, useTx } from "./ui";

const usd8 = (s: string) => parseUnits(s || "0", 8);
const fmtUsd = (v?: bigint) => (v === undefined ? "…" : `$${formatUnits(v, 8)}`);

export default function App() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const dep = deployments[chainId] ?? {};
  const [vault, setVault] = useState<Address | "">("");

  return (
    <Shell
      title="SlipGuard"
      tagline="Swap limits for AI agents, enforced on-chain. You fund your own vault; the agent can only swap tokens you allow, through routers you allow, within a per-swap and a daily USD cap, and never at a price worse than the Chainlink price minus your slippage limit. It can never withdraw."
      steps={[
        "Create a vault you own, deposit USDC or WETH and set the price feeds.",
        "Grant an agent key: expiry, max slippage, per-swap and daily caps, allowed tokens and routers.",
        "The agent swaps inside those limits. Swap output stays in the vault.",
        "Pause, revoke or withdraw at any time.",
      ]}
      contractLabel="Vault factory"
      contractOf={(id) => deployments[id]?.factory}
      refs={[
        { label: "USDC", address: dep.usdc },
        { label: "WETH", address: dep.weth },
        { label: "Chainlink ETH/USD", address: known[chainId]?.ethUsd },
        { label: "Chainlink USDC/USD", address: known[chainId]?.usdcUsd },
      ]}
      risk={
        <>
          <strong>Real funds.</strong> This contract is not audited. Deposited tokens can be swapped by the agent you
          grant, within its caps and slippage limit, through the routers you allow. Only deposit amounts you can
          afford to lose.
        </>
      }
    >
      {!isConnected && <Empty>Connect a wallet to create a vault or manage one you already own.</Empty>}

      {isConnected && address && (
        <>
          <VaultPicker owner={address} factory={dep.factory} vault={vault} setVault={setVault} />
          {vault && isAddress(vault) && (
            <>
              <VaultOverview vault={vault} usdc={dep.usdc} weth={dep.weth} chainId={chainId} />
              <GrantAgent vault={vault} usdc={dep.usdc} weth={dep.weth} chainId={chainId} />
              <AgentView vault={vault} usdc={dep.usdc} weth={dep.weth} />
            </>
          )}
        </>
      )}
    </Shell>
  );
}

function VaultPicker({
  owner,
  factory,
  vault,
  setVault,
}: {
  owner: Address;
  factory?: Address;
  vault: Address | "";
  setVault: (v: Address | "") => void;
}) {
  const { writeContractAsync, run, status } = useTx();
  const list = useReadContract({
    address: factory,
    abi: slipGuardVaultFactoryAbi,
    functionName: "vaultsOf",
    args: [owner],
    query: { enabled: !!factory },
  });
  const vaults = (list.data as Address[] | undefined) ?? [];

  return (
    <div className="card">
      <h2>1. Choose a vault</h2>
      <p className="muted">A vault is your own contract. It holds the tokens and enforces the agent limits.</p>
      <div className="field-label">Your vaults on this network</div>
      {!factory ? (
        <Empty>No factory on this network, so vaults cannot be listed or created here.</Empty>
      ) : list.isLoading ? (
        <Loading>Looking up your vaults…</Loading>
      ) : vaults.length > 0 ? (
        <div className="row">
          {vaults.map((v) => (
            <button key={v} className={v === vault ? "seg seg-on" : "seg"} aria-pressed={v === vault} onClick={() => setVault(v)}>
              <code>{short(v)}</code>
              <span className="seg-sub">{v === vault ? "selected" : "select"}</span>
            </button>
          ))}
        </div>
      ) : (
        <Empty>This wallet has no vaults yet. Create one below, or paste the address of a vault you want to inspect.</Empty>
      )}
      <div className="row">
        <button
          disabled={!factory}
          onClick={async () => {
            const ok = await run("Create vault", () =>
              writeContractAsync({ address: factory!, abi: slipGuardVaultFactoryAbi, functionName: "createVault" }),
            );
            if (ok) {
              const next = ((await list.refetch()).data as Address[] | undefined) ?? [];
              if (next.length) setVault(next[next.length - 1]);
            }
          }}
        >
          Create new vault
        </button>
        <label>
          Or open a vault by address
          <input value={vault} placeholder="0x…" spellCheck={false} onChange={(e) => setVault(e.target.value.trim() as Address)} />
        </label>
      </div>
      {vault && !isAddress(vault) && <div className="bad muted">That is not a valid address (0x followed by 40 hex characters).</div>}
      <Hint>
        “Create new vault” deploys a vault contract owned by your connected wallet. One transaction, gas only — no
        funds move.
      </Hint>
      {status}
    </div>
  );
}

function VaultOverview({
  vault,
  usdc,
  weth,
  chainId,
}: {
  vault: Address;
  usdc?: Address;
  weth?: Address;
  chainId: number;
}) {
  const { address } = useAccount();
  const { writeContractAsync, run, status, safe, fail } = useTx();
  const feeds = known[chainId];
  const [amt, setAmt] = useState("100");
  const [token, setToken] = useState<"usdc" | "weth">("usdc");
  const tokenAddr = token === "usdc" ? usdc : weth;
  const decimals = token === "usdc" ? 6 : 18;

  const owner = useReadContract({ address: vault, abi: slipGuardVaultAbi, functionName: "owner" });
  const paused = useReadContract({ address: vault, abi: slipGuardVaultAbi, functionName: "paused" });
  const permit2 = useReadContract({ address: vault, abi: slipGuardVaultAbi, functionName: "permit2Enabled" });
  const ethBal = useBalance({ address: vault });
  const usdcBal = useReadContract({
    address: usdc,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [vault],
    query: { enabled: !!usdc },
  });
  const wethBal = useReadContract({
    address: weth,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [vault],
    query: { enabled: !!weth },
  });
  const isOwner = !!address && owner.data && address.toLowerCase() === (owner.data as string).toLowerCase();

  const approveAndDeposit = async () => {
    if (!tokenAddr) return;
    const value = parseUnits(amt || "0", decimals);
    if (value === 0n) return fail("Amount must be greater than 0.");
    const ok = await run(`Approve ${token.toUpperCase()}`, () =>
      writeContractAsync({ address: tokenAddr, abi: erc20Abi, functionName: "approve", args: [vault, value] }),
    );
    if (!ok) return;
    await run("Deposit", () =>
      writeContractAsync({ address: vault, abi: slipGuardVaultAbi, functionName: "deposit", args: [tokenAddr, value] }),
    );
  };

  return (
    <div className="card">
      <h2>2. Balances and controls (owner)</h2>
      <dl className="dl">
        <dt>Vault</dt>
        <dd>
          <Addr value={vault} full />
        </dd>
        <dt>Owner</dt>
        <dd>
          <Addr value={owner.data as string | undefined} /> {isOwner && <span className="ok">(you)</span>}
        </dd>
        <dt>Agent swaps</dt>
        <dd>
          {paused.data === undefined ? "…" : paused.data ? <span className="bad">Paused</span> : <span className="ok">Active</span>} ·
          Permit2 {permit2.data ? "on" : "off"}
        </dd>
      </dl>
      {owner.data && !isOwner && (
        <div className="info">
          You are not the owner of this vault, so deposits, withdrawals and settings are hidden. You can still read
          balances and agent limits.
        </div>
      )}
      <table>
        <tbody>
          <tr>
            <td>ETH</td>
            <td>{ethBal.data ? formatUnits(ethBal.data.value, 18) : "…"}</td>
          </tr>
          <tr>
            <td>USDC</td>
            <td>{usdcBal.data !== undefined ? formatUnits(usdcBal.data as bigint, 6) : "…"}</td>
          </tr>
          <tr>
            <td>WETH</td>
            <td>{wethBal.data !== undefined ? formatUnits(wethBal.data as bigint, 18) : "…"}</td>
          </tr>
        </tbody>
      </table>
      {isOwner && (
        <>
          <h3>Deposit and withdraw</h3>
          <div className="row">
            <label>
              Token
              <select value={token} onChange={(e) => setToken(e.target.value as "usdc" | "weth")}>
                <option value="usdc">USDC</option>
                <option value="weth">WETH</option>
              </select>
            </label>
            <label>
              Amount
              <input value={amt} inputMode="decimal" onChange={(e) => setAmt(e.target.value)} />
            </label>
            <button disabled={!tokenAddr} onClick={safe(approveAndDeposit)}>
              Approve + deposit
            </button>
            <button
              className="ghost"
              disabled={!tokenAddr}
              onClick={() =>
                tokenAddr &&
                run("Withdraw", () =>
                  writeContractAsync({
                    address: vault,
                    abi: slipGuardVaultAbi,
                    functionName: "withdraw",
                    args: [tokenAddr, address!, parseUnits(amt || "0", decimals)],
                  }),
                )
              }
            >
              Withdraw
            </button>
          </div>
          <Hint>
            Deposit asks twice: an approval for exactly this amount, then the deposit, which moves the tokens from your
            wallet into the vault. Withdraw sends that amount from the vault back to your connected wallet and works
            even while paused.
          </Hint>
          <h3>Setup and safety</h3>
          <div className="row">
            <button
              className="ghost"
              onClick={() =>
                run("Wrap ETH", () => writeContractAsync({ address: vault, abi: slipGuardVaultAbi, functionName: "wrapETH" }))
              }
            >
              Wrap vault ETH
            </button>
            {feeds?.ethUsd && weth && (
              <button
                className="ghost"
                onClick={() =>
                  run("Set ETH/USD feed", () =>
                    writeContractAsync({
                      address: vault,
                      abi: slipGuardVaultAbi,
                      functionName: "setFeed",
                      args: [weth, feeds.ethUsd!, BigInt(60 * 75)],
                    }),
                  )
                }
              >
                Set ETH/USD feed
              </button>
            )}
            {feeds?.usdcUsd && usdc && (
              <button
                className="ghost"
                onClick={() =>
                  run("Set USDC/USD feed", () =>
                    writeContractAsync({
                      address: vault,
                      abi: slipGuardVaultAbi,
                      functionName: "setFeed",
                      args: [usdc, feeds.usdcUsd!, BigInt(60 * 60 * 25)],
                    }),
                  )
                }
              >
                Set USDC/USD feed
              </button>
            )}
            <button
              className="ghost"
              onClick={() =>
                run(permit2.data ? "Disable Permit2" : "Enable Permit2", () =>
                  writeContractAsync({
                    address: vault,
                    abi: slipGuardVaultAbi,
                    functionName: "setPermit2Enabled",
                    args: [!permit2.data],
                  }),
                )
              }
            >
              {permit2.data ? "Disable" : "Enable"} Permit2
            </button>
            <button
              className={paused.data ? "ghost" : "danger"}
              onClick={() =>
                run(paused.data ? "Unpause" : "Pause", () =>
                  writeContractAsync({
                    address: vault,
                    abi: slipGuardVaultAbi,
                    functionName: paused.data ? "unpause" : "pause",
                  }),
                )
              }
            >
              {paused.data ? "Unpause" : "Pause agents"}
            </button>
          </div>
          <Hint>
            The price feeds are the Chainlink oracles the vault uses to value swaps and enforce slippage; an agent
            cannot swap a token until its feed is set. “Wrap vault ETH” converts ETH held by the vault to WETH inside
            the vault. Permit2 lets allowed routers pull tokens through Uniswap's Permit2 contract. Pause blocks every
            agent swap at once; withdrawals still work. None of these move funds out of the vault.
          </Hint>
        </>
      )}
      {status}
    </div>
  );
}

function GrantAgent({
  vault,
  usdc,
  weth,
  chainId,
}: {
  vault: Address;
  usdc?: Address;
  weth?: Address;
  chainId: number;
}) {
  const { writeContractAsync, run, status, safe, fail } = useTx();
  const routers = known[chainId]?.routers ?? [];
  const [agent, setAgent] = useState("");
  const [hours, setHours] = useState("168");
  const [slip, setSlip] = useState("50");
  const [maxTx, setMaxTx] = useState("1000");
  const [daily, setDaily] = useState("5000");
  const [allowUsdc, setAllowUsdc] = useState(true);
  const [allowWeth, setAllowWeth] = useState(true);
  const [picked, setPicked] = useState<Record<string, boolean>>({});

  const grant = async (tighten: boolean) => {
    if (!isAddress(agent)) return;
    const h = Number(hours);
    if (!Number.isFinite(h) || h <= 0) return fail("Expiry must be a number of hours greater than 0.");
    const bps = Number(slip);
    if (!Number.isInteger(bps) || bps < 0 || bps > 10_000) return fail("Max slippage must be a whole number of basis points (50 = 0.5%).");
    const expiry = BigInt(Math.floor(Date.now() / 1000 + h * 3600));
    const perTx = usd8(maxTx);
    const perDay = usd8(daily);
    const fn = tighten ? "setPolicy" : "grantAgent";
    const ok = await run(tighten ? "Update policy" : "Grant agent", () =>
      writeContractAsync({
        address: vault,
        abi: slipGuardVaultAbi,
        functionName: fn,
        args: [agent as Address, expiry, bps, perTx, perDay],
      }),
    );
    if (!ok || tighten) return;
    if (allowUsdc && usdc) {
      await run("Allow USDC", () =>
        writeContractAsync({
          address: vault,
          abi: slipGuardVaultAbi,
          functionName: "setTokenAllowed",
          args: [agent as Address, usdc, true],
        }),
      );
    }
    if (allowWeth && weth) {
      await run("Allow WETH", () =>
        writeContractAsync({
          address: vault,
          abi: slipGuardVaultAbi,
          functionName: "setTokenAllowed",
          args: [agent as Address, weth, true],
        }),
      );
    }
    for (const r of routers) {
      if (!picked[r.address]) continue;
      await run(`Allow ${r.label}`, () =>
        writeContractAsync({
          address: vault,
          abi: slipGuardVaultAbi,
          functionName: "setRouterAllowed",
          args: [agent as Address, r.address, true],
        }),
      );
    }
  };

  return (
    <div className="card">
      <h2>3. Agent key (owner)</h2>
      <p className="muted">
        The agent can only swap the ticked tokens through the ticked routers, inside these limits. It can never
        withdraw.
      </p>
      <div className="row">
        <label>
          Agent address
          <input value={agent} spellCheck={false} onChange={(e) => setAgent(e.target.value.trim())} placeholder="0x…" />
        </label>
        <label>
          Expiry (hours)
          <input value={hours} onChange={(e) => setHours(e.target.value)} />
        </label>
        <label>
          Max slippage (bps, 50 = 0.5%)
          <input value={slip} onChange={(e) => setSlip(e.target.value)} />
        </label>
        <label>
          Max per swap (USD)
          <input value={maxTx} onChange={(e) => setMaxTx(e.target.value)} />
        </label>
        <label>
          Daily cap (USD)
          <input value={daily} onChange={(e) => setDaily(e.target.value)} />
        </label>
      </div>
      <div className="field-label">Tokens the agent may swap</div>
      <div className="row checks">
        <label>
          <input type="checkbox" checked={allowUsdc} onChange={(e) => setAllowUsdc(e.target.checked)} /> USDC
        </label>
        <label>
          <input type="checkbox" checked={allowWeth} onChange={(e) => setAllowWeth(e.target.checked)} /> WETH
        </label>
      </div>
      <div className="field-label">Routers the agent may call</div>
      {routers.length === 0 && <p className="muted">No known routers on this network. Allow routers directly on the vault contract.</p>}
      {routers.map((r) => (
        <div className="row checks" key={r.address}>
          <label>
            <input
              type="checkbox"
              checked={!!picked[r.address]}
              onChange={(e) => setPicked((p) => ({ ...p, [r.address]: e.target.checked }))}
            />{" "}
            {r.label}
          </label>
          <Addr value={r.address} />
        </div>
      ))}
      <div className="row">
        <button disabled={!isAddress(agent)} onClick={safe(() => grant(false))}>
          Grant agent
        </button>
        <button className="ghost" disabled={!isAddress(agent)} onClick={safe(() => grant(true))}>
          Update policy only
        </button>
      </div>
      {agent && !isAddress(agent) && <div className="bad muted">Agent is not a valid address.</div>}
      <Hint>
        “Grant agent” is several transactions in a row: the grant with these limits, then one per ticked token and
        router. Granting an existing agent again replaces its limits and adds the ticked tokens and routers. “Update policy only” is one transaction
        that changes expiry, slippage and caps for an existing agent and keeps its allowlists. No funds move.
      </Hint>
      {status}
    </div>
  );
}

function AgentView({ vault, usdc, weth }: { vault: Address; usdc?: Address; weth?: Address }) {
  const client = usePublicClient();
  const { writeContractAsync, run, status } = useTx();
  const [agent, setAgent] = useState("");
  const enabled = isAddress(agent);
  const info = useReadContract({
    address: vault,
    abi: slipGuardVaultAbi,
    functionName: "agents",
    args: enabled ? [agent as Address] : undefined,
    query: { enabled },
  });
  const spendable = useReadContract({
    address: vault,
    abi: slipGuardVaultAbi,
    functionName: "spendableUsdNow",
    args: enabled ? [agent as Address] : undefined,
    query: { enabled },
  });
  const a = info.data as
    | readonly [boolean, bigint, number, number, bigint, bigint, bigint, bigint]
    | undefined;

  const logs = useQuery({
    queryKey: ["swaps", vault, client?.chain?.id],
    enabled: !!client,
    queryFn: async () => {
      const block = await client!.getBlockNumber();
      const from = block > 49_000n ? block - 49_000n : 0n;
      return client!.getLogs({
        address: vault,
        event: {
          type: "event",
          name: "Swapped",
          inputs: [
            { name: "agent", type: "address", indexed: true },
            { name: "tokenIn", type: "address", indexed: true },
            { name: "tokenOut", type: "address", indexed: true },
            { name: "router", type: "address", indexed: false },
            { name: "amountIn", type: "uint256", indexed: false },
            { name: "amountOut", type: "uint256", indexed: false },
            { name: "minOut", type: "uint256", indexed: false },
            { name: "usdIn", type: "uint256", indexed: false },
            { name: "spentUsdInWindow", type: "uint256", indexed: false },
            { name: "windowStart", type: "uint64", indexed: false },
          ],
        },
        fromBlock: from,
        toBlock: "latest",
      });
    },
  });

  const decOf = useMemo(() => {
    const m: Record<string, { label: string; decimals: number }> = {};
    if (usdc) m[usdc.toLowerCase()] = { label: "USDC", decimals: 6 };
    if (weth) m[weth.toLowerCase()] = { label: "WETH", decimals: 18 };
    return m;
  }, [usdc, weth]);

  return (
    <div className="card">
      <h2>4. Agent limits and recent swaps</h2>
      <div className="row">
        <label>
          Agent address
          <input value={agent} spellCheck={false} onChange={(e) => setAgent(e.target.value.trim())} placeholder="0x…" />
        </label>
        <button
          className="danger"
          disabled={!enabled}
          onClick={() =>
            run("Revoke agent", () =>
              writeContractAsync({
                address: vault,
                abi: slipGuardVaultAbi,
                functionName: "revokeAgent",
                args: [agent as Address],
              }),
            )
          }
        >
          Revoke agent
        </button>
      </div>
      <Hint tone="danger">
        Revoke removes this agent's swap rights immediately (owner or guardian only). Funds stay in the vault.
      </Hint>
      {!enabled && <Empty>Enter an agent address to see its limits.</Empty>}
      {enabled && info.isLoading && <Loading />}
      {a && (
        <table>
          <tbody>
            <tr>
              <td>Status</td>
              <td>{a[0] ? <span className="ok">Active</span> : <span className="bad">Not active (never granted or revoked)</span>}</td>
            </tr>
            <tr>
              <td>Expiry</td>
              <td>{a[1] > 0n ? new Date(Number(a[1]) * 1000).toLocaleString() : "—"}</td>
            </tr>
            <tr>
              <td>Max slippage</td>
              <td>{String(a[3])} bps</td>
            </tr>
            <tr>
              <td>Max per tx</td>
              <td>{fmtUsd(a[4])}</td>
            </tr>
            <tr>
              <td>Daily cap / spent</td>
              <td>
                {fmtUsd(a[5])} / {fmtUsd(a[7])}
              </td>
            </tr>
            <tr>
              <td>Spendable now</td>
              <td>
                {spendable.data ? `${fmtUsd(spendable.data[0])} until ${new Date(Number(spendable.data[1]) * 1000).toLocaleString()}` : "…"}
              </td>
            </tr>
          </tbody>
        </table>
      )}
      <h3>Recent swaps</h3>
      {logs.isLoading && <Loading>Reading swap events…</Loading>}
      {logs.isError && <div className="muted">Could not read swap events from this RPC.</div>}
      {logs.data && logs.data.length === 0 && <Empty>No swaps by any agent in the last ~49,000 blocks.</Empty>}
      {logs.data && logs.data.length > 0 && (
        <table>
          <thead>
            <tr>
              <th>Tx</th>
              <th>Agent</th>
              <th>In</th>
              <th>Out</th>
              <th>USD</th>
            </tr>
          </thead>
          <tbody>
            {[...logs.data].reverse().map((l) => {
              const tin = decOf[(l.args.tokenIn ?? "").toLowerCase()];
              const tout = decOf[(l.args.tokenOut ?? "").toLowerCase()];
              return (
                <tr key={`${l.transactionHash}-${l.logIndex}`}>
                  <td>
                    <Addr value={l.transactionHash ?? undefined} kind="tx" copy={false} />
                  </td>
                  <td>
                    <Addr value={l.args.agent} copy={false} />
                  </td>
                  <td>
                    {l.args.amountIn !== undefined ? formatUnits(l.args.amountIn, tin?.decimals ?? 18) : ""} {tin?.label ?? short(l.args.tokenIn)}
                  </td>
                  <td>
                    {l.args.amountOut !== undefined ? formatUnits(l.args.amountOut, tout?.decimals ?? 18) : ""} {tout?.label ?? short(l.args.tokenOut)}
                  </td>
                  <td>{fmtUsd(l.args.usdIn)}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
      {status}
    </div>
  );
}
