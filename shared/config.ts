import "dotenv/config";
import { type Address, type Hex, isAddress, isHex } from "viem";

function req(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`missing env var ${name} — see .env.example`);
  return v;
}
function addr(name: string): Address {
  const v = req(name);
  if (!isAddress(v)) throw new Error(`env var ${name} is not an address: ${v}`);
  return v;
}
function hex(name: string): Hex {
  const v = req(name);
  if (!isHex(v)) throw new Error(`env var ${name} is not hex`);
  return v;
}

export const config = {
  rpcUrl: req("BASE_SEPOLIA_RPC_URL"),
  vault: addr("VAULT_ADDRESS"),
  usdc: addr("USDC_ADDRESS"),
  payee: addr("PAYEE_ADDRESS"),
  agent: addr("AGENT_ADDRESS"),
  agentKey: () => hex("AGENT_PRIVATE_KEY"), // lazy: server never needs it
  port: Number(process.env.PORT ?? 3402),
  serverUrl: process.env.SERVER_URL ?? `http://localhost:${process.env.PORT ?? 3402}`,
  /** Price of the demo resource, in 6-decimal USDC units. */
  price: BigInt(process.env.PRICE ?? "1000000"),
} as const;
