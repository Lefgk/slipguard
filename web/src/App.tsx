import { useMemo, useState } from "react";
import {
  useAccount,
  useChainId,
  useConnect,
  useDisconnect,
  usePublicClient,
  useReadContract,
  useSwitchChain,
  useWriteContract,
  useBalance,
} from "wagmi";
import { useQuery } from "@tanstack/react-query";
import { erc20Abi, formatUnits, isAddress, parseUnits, type Address } from "viem";
import { slipGuardVaultAbi, slipGuardVaultFactoryAbi } from "./abi";
import { deployments, known } from "./config";

const short = (a?: string) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "");
const usd8 = (s: string) => parseUnits(s || "0", 8);
const fmtUsd = (v?: bigint) => (v === undefined ? "…" : `$${formatUnits(v, 8)}`);

export default function App() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain, chains } = useSwitchChain();
  const dep = deployments[chainId] ?? {};
  const [vault, setVault] = useState<Address | "">("");

  return (
    <div className="wrap">
      <h1>SlipGuard</h1>
      <div className="muted">
        On-chain swap limits for AI agents: token and router allowlists, Chainlink max slippage, per-tx and daily
        USD caps, expiry, instant pause and revoke. Prototype — not audited. Ethereum, Base and local anvil.
      </div>

      <div className="card">
        <h2>Wallet</h2>
        {!isConnected ? (
          <div className="row">
            {connectors.map((c) => (
              <button key={c.uid} onClick={() => connect({ connector: c })}>
                Connect {c.name}
              </button>
            ))}
          </div>
        ) : (
          <div className="row">
            <span>
              Connected <code>{address}</code>
            </span>
            <button className="ghost" onClick={() => disconnect()}>
              Disconnect
            </button>
          </div>
        )}
        <div className="row">
          {chains.map((c) => (
            <button key={c.id} className={c.id === chainId ? "" : "ghost"} onClick={() => switchChain({ chainId: c.id })}>
              {c.name}
            </button>
          ))}
        </div>
        {!deployments[chainId] && <div className="warn">Unsupported chain: use Ethereum, Base or local anvil.</div>}
        {deployments[chainId] && !dep.factory && (
          <div className="warn">
            <strong>Not deployed yet</strong> on this chain — the factory address is empty. Core flows stay disabled
            until you deploy (<code>make deploy-mainnet</code> or <code>make deploy-base</code>), which writes the
            address into <code>web/src/deployments.json</code>. You can still paste an existing vault address below
            after connecting.
          </div>
        )}
        {deployments[chainId]?.live && dep.factory && (
          <div className="warn">
            Live chain with real funds. This contract is NOT audited — only deposit amounts you can afford to lose.
          </div>
        )}
      </div>

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
    </div>
  );
}

function useTx() {
  const { writeContractAsync } = useWriteContract();
  const client = usePublicClient();
  const [status, setStatus] = useState("");
  const run = async (label: string, fn: () => Promise<`0x${string}`>) => {
    try {
      setStatus(`${label}: confirm in wallet…`);
      const hash = await fn();
      setStatus(`${label}: pending ${short(hash)}`);
      await client!.waitForTransactionReceipt({ hash });
      setStatus(`${label}: confirmed ✓`);
      return true;
    } catch (e) {
      setStatus(`${label}: ${(e as Error).message.split("\n")[0]}`);
      return false;
    }
  };
  return { writeContractAsync, run, status };
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
  const [paste, setPaste] = useState("");

  return (
    <div className="card">
      <h2>Vault</h2>
      <div className="row">
        <button
          disabled={!factory}
          onClick={() =>
            run("create vault", () =>
              writeContractAsync({ address: factory!, abi: slipGuardVaultFactoryAbi, functionName: "createVault" }),
            ).then((ok) => {
              if (ok) void list.refetch();
            })
          }
        >
          Create vault
        </button>
        <select value={vault} onChange={(e) => setVault(e.target.value as Address)}>
          <option value="">Select a vault…</option>
          {vaults.map((v) => (
            <option key={v} value={v}>
              {v}
            </option>
          ))}
        </select>
      </div>
      <div className="row">
        <label>
          Or paste a vault address
          <input value={paste} onChange={(e) => setPaste(e.target.value)} placeholder="0x…" />
        </label>
        <button
          className="ghost"
          disabled={!isAddress(paste)}
          onClick={() => setVault(paste as Address)}
        >
          Use
        </button>
      </div>
      <div className="muted">{status}</div>
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
  const { writeContractAsync, run, status } = useTx();
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
    const ok = await run("approve", () =>
      writeContractAsync({ address: tokenAddr, abi: erc20Abi, functionName: "approve", args: [vault, value] }),
    );
    if (!ok) return;
    await run("deposit", () =>
      writeContractAsync({ address: vault, abi: slipGuardVaultAbi, functionName: "deposit", args: [tokenAddr, value] }),
    );
  };

  return (
    <div className="card">
      <h2>Balances & controls</h2>
      <div className="muted">
        Owner <code>{short(owner.data as string)}</code> · {paused.data ? <span className="bad">paused</span> : <span className="ok">active</span>} · Permit2{" "}
        {permit2.data ? "on" : "off"}
      </div>
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
              <input value={amt} onChange={(e) => setAmt(e.target.value)} />
            </label>
            <button onClick={approveAndDeposit}>Deposit</button>
            <button
              className="ghost"
              onClick={() =>
                tokenAddr &&
                run("withdraw", () =>
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
          <div className="row">
            <button
              className="ghost"
              onClick={() =>
                run("wrap ETH", () => writeContractAsync({ address: vault, abi: slipGuardVaultAbi, functionName: "wrapETH" }))
              }
            >
              Wrap vault ETH
            </button>
            {feeds?.ethUsd && weth && (
              <button
                className="ghost"
                onClick={() =>
                  run("set ETH/USD feed", () =>
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
                  run("set USDC/USD feed", () =>
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
                run("toggle Permit2", () =>
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
                run(paused.data ? "unpause" : "pause", () =>
                  writeContractAsync({
                    address: vault,
                    abi: slipGuardVaultAbi,
                    functionName: paused.data ? "unpause" : "pause",
                  }),
                )
              }
            >
              {paused.data ? "Unpause" : "Pause"}
            </button>
          </div>
        </>
      )}
      <div className="muted">{status}</div>
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
  const { writeContractAsync, run, status } = useTx();
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
    const expiry = BigInt(Math.floor(Date.now() / 1000) + Number(hours || "0") * 3600);
    const fn = tighten ? "setPolicy" : "grantAgent";
    const ok = await run(tighten ? "tighten" : "grant", () =>
      writeContractAsync({
        address: vault,
        abi: slipGuardVaultAbi,
        functionName: fn,
        args: [agent as Address, expiry, Number(slip || "0"), usd8(maxTx), usd8(daily)],
      }),
    );
    if (!ok || tighten) return;
    if (allowUsdc && usdc) {
      await run("allow USDC", () =>
        writeContractAsync({
          address: vault,
          abi: slipGuardVaultAbi,
          functionName: "setTokenAllowed",
          args: [agent as Address, usdc, true],
        }),
      );
    }
    if (allowWeth && weth) {
      await run("allow WETH", () =>
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
      await run(`allow ${r.label}`, () =>
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
      <h2>Grant / tighten agent</h2>
      <div className="row">
        <label>
          Agent address
          <input value={agent} onChange={(e) => setAgent(e.target.value)} placeholder="0x…" />
        </label>
        <label>
          Expiry (hours)
          <input value={hours} onChange={(e) => setHours(e.target.value)} />
        </label>
        <label>
          Max slippage (bps)
          <input value={slip} onChange={(e) => setSlip(e.target.value)} />
        </label>
        <label>
          Max per tx (USD)
          <input value={maxTx} onChange={(e) => setMaxTx(e.target.value)} />
        </label>
        <label>
          Daily cap (USD)
          <input value={daily} onChange={(e) => setDaily(e.target.value)} />
        </label>
      </div>
      <div className="row">
        <label>
          <input type="checkbox" checked={allowUsdc} onChange={(e) => setAllowUsdc(e.target.checked)} /> USDC
        </label>
        <label>
          <input type="checkbox" checked={allowWeth} onChange={(e) => setAllowWeth(e.target.checked)} /> WETH
        </label>
      </div>
      {routers.map((r) => (
        <div className="row" key={r.address}>
          <label>
            <input
              type="checkbox"
              checked={!!picked[r.address]}
              onChange={(e) => setPicked((p) => ({ ...p, [r.address]: e.target.checked }))}
            />{" "}
            {r.label} <code>{short(r.address)}</code>
          </label>
        </div>
      ))}
      <div className="row">
        <button disabled={!isAddress(agent)} onClick={() => grant(false)}>
          Grant agent
        </button>
        <button className="ghost" disabled={!isAddress(agent)} onClick={() => grant(true)}>
          Tighten policy
        </button>
      </div>
      <div className="muted">{status}</div>
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
      <h2>View agent / recent swaps</h2>
      <div className="row">
        <label>
          Agent
          <input value={agent} onChange={(e) => setAgent(e.target.value)} placeholder="0x…" />
        </label>
        <button
          className="danger"
          disabled={!enabled}
          onClick={() =>
            run("revoke", () =>
              writeContractAsync({
                address: vault,
                abi: slipGuardVaultAbi,
                functionName: "revokeAgent",
                args: [agent as Address],
              }),
            )
          }
        >
          Revoke
        </button>
      </div>
      {a && (
        <table>
          <tbody>
            <tr>
              <td>Status</td>
              <td>{a[0] ? <span className="ok">active</span> : <span className="bad">revoked</span>}</td>
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
      <h2 style={{ marginTop: 16 }}>Recent swaps</h2>
      {logs.data && logs.data.length === 0 && <div className="muted">No swaps in the last ~49k blocks.</div>}
      {logs.data && logs.data.length > 0 && (
        <table>
          <thead>
            <tr>
              <th>Block</th>
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
                  <td>{l.blockNumber?.toString()}</td>
                  <td>
                    <code>{short(l.args.agent)}</code>
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
      <div className="muted">{status}</div>
    </div>
  );
}
