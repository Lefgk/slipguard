import { http, createConfig } from "wagmi";
import { mainnet, base, foundry } from "wagmi/chains";
import { injected } from "wagmi/connectors";
import type { Address } from "viem";
import deploymentsFile from "./deployments.json";

const env = import.meta.env;

export const config = createConfig({
  chains: [base, mainnet, foundry],
  connectors: [injected()],
  transports: {
    [mainnet.id]: http(env.VITE_MAINNET_RPC || undefined),
    [base.id]: http(env.VITE_BASE_RPC || undefined),
    [foundry.id]: http(env.VITE_ANVIL_RPC || "http://127.0.0.1:8624"),
  },
});

const asAddr = (v?: string) => (v && /^0x[0-9a-fA-F]{40}$/.test(v) ? (v as Address) : undefined);

export type KnownRouter = { label: string; address: Address };

export const known: Record<
  number,
  { ethUsd?: Address; usdcUsd?: Address; routers: KnownRouter[]; permit2: Address }
> = {
  [mainnet.id]: {
    ethUsd: "0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419",
    usdcUsd: "0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6",
    permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
    routers: [
      { label: "Uniswap Universal Router", address: "0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af" },
      { label: "Uniswap Universal Router 2.1.2", address: "0x23617e59A5925b2A4Bf75d73ff6711cD0b29De85" },
      { label: "Uniswap SwapRouter02", address: "0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45" },
      { label: "1inch Aggregation Router V6", address: "0x111111125421cA6dc452d289314280a0f8842A65" },
      { label: "0x Exchange Proxy", address: "0xDef1C0ded9bec7F1a1670819833240f027b25EfF" },
      { label: "0x Settler", address: "0xaddC26a3854feaBFd20d6BF658254088D83a425A" },
    ],
  },
  [base.id]: {
    ethUsd: "0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70",
    usdcUsd: "0x7e860098F58bBFC8648a4311b374B1D669a2bc6B",
    permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
    routers: [
      { label: "Uniswap Universal Router", address: "0x6fF5693b99212Da76ad316178A184AB56D299b43" },
      { label: "Uniswap Universal Router 2.1.2", address: "0xd6145b2D3F379919E8CdEda7B97e37c4b2Ca9c40" },
      { label: "Uniswap SwapRouter02", address: "0x2626664c2603336E57B271c5C0b26F421741e481" },
      { label: "1inch Aggregation Router V6", address: "0x111111125421cA6dc452d289314280a0f8842A65" },
      { label: "0x Exchange Proxy", address: "0xDef1C0ded9bec7F1a1670819833240f027b25EfF" },
      { label: "0x Settler", address: "0x103502909141F7025a94b7b99A276dCD128e21a8" },
    ],
  },
  [foundry.id]: {
    permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
    routers: [],
  },
};

type DeploymentRow = { factory?: string; usdc?: string; weth?: string };
const file = deploymentsFile as Record<string, DeploymentRow>;
const fromFile = (chainId: number) => {
  const row = file[String(chainId)] ?? {};
  return { factory: asAddr(row.factory), usdc: asAddr(row.usdc), weth: asAddr(row.weth) };
};

/** Per-chain deployment addresses. Env vars override deployments.json. Empty factory = not deployed yet. */
export const deployments: Record<number, { factory?: Address; usdc?: Address; weth?: Address; live: boolean }> = {
  [mainnet.id]: {
    factory: asAddr(env.VITE_FACTORY_MAINNET) ?? fromFile(mainnet.id).factory,
    usdc: fromFile(mainnet.id).usdc ?? "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    weth: fromFile(mainnet.id).weth ?? "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
    live: true,
  },
  [base.id]: {
    factory: asAddr(env.VITE_FACTORY_BASE) ?? fromFile(base.id).factory,
    usdc: fromFile(base.id).usdc ?? "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    weth: fromFile(base.id).weth ?? "0x4200000000000000000000000000000000000006",
    live: true,
  },
  // Anvil defaults match a fresh `script/deploy-anvil.sh` (factory, MockUSDC, MockWETH in that order).
  [foundry.id]: {
    factory: asAddr(env.VITE_FACTORY_ANVIL) ?? fromFile(foundry.id).factory ?? "0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0",
    usdc: asAddr(env.VITE_USDC_ANVIL) ?? fromFile(foundry.id).usdc ?? "0x5FbDB2315678afecb367f032d93F642f64180aa3",
    weth: asAddr(env.VITE_WETH_ANVIL) ?? fromFile(foundry.id).weth ?? "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512",
    live: false,
  },
};

declare module "wagmi" {
  interface Register {
    config: typeof config;
  }
}
