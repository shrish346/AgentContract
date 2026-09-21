import { createPublicClient, http } from "viem";
import { baseSepolia } from "viem/chains";
import { config } from "./config.js";
import { vaultAbi } from "./AgentBudget.abi.js";

export const chain = baseSepolia;
export { vaultAbi };

export const publicClient = createPublicClient({
  chain,
  transport: http(config.rpcUrl),
});

export function fmtUsdc(units: bigint): string {
  const whole = units / 1_000_000n;
  const frac = (units % 1_000_000n).toString().padStart(6, "0").replace(/0+$/, "");
  return frac ? `$${whole}.${frac}` : `$${whole}`;
}
