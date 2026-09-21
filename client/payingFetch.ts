/**
 * fetch() that pays on 402.
 *
 * Payment lives here, in the transport layer. It is not a tool, not a callable
 * action, and never exposed to any agent logic above it. The agent asks for a
 * URL; it gets the resource or a PaymentRefused error. That's the whole API.
 *
 * No limits are checked here. If the vault refuses, the revert is decoded into
 * a readable reason and thrown. We never retry a refused payment.
 */
import {
  BaseError,
  ContractFunctionRevertedError,
  createWalletClient,
  http,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { chain, publicClient, vaultAbi, fmtUsdc } from "../shared/chain.js";
import { config } from "../shared/config.js";
import type { PaymentOffer } from "../server/paywall.js";

export const PAYMENT_HEADER = "x-payment-tx";

/** Thrown when the vault (or the server) refuses. Callers should stop, not retry. */
export class PaymentRefused extends Error {
  constructor(
    public readonly code: string,
    message: string,
    public readonly detail?: unknown,
  ) {
    super(message);
    this.name = "PaymentRefused";
  }
}

const REVERT_MESSAGES: Record<string, string> = {
  AgentInactive: "agent is not registered or has been revoked",
  PayeeNotAllowed: "payee is not on the operator's allowlist",
  DuplicateRequest: "requestId has already been paid",
  OverPerCallLimit: "amount exceeds the per-call ceiling",
  OverDailyLimit: "daily spending limit reached",
};

const account = privateKeyToAccount(config.agentKey());
const walletClient = createWalletClient({ account, chain, transport: http(config.rpcUrl) });

export type PaidReceipt = { txHash: Hex; blockNumber: bigint; amount: bigint; payee: Address; requestId: Hex };

export async function payingFetch(
  input: string,
  init: RequestInit = {},
  onPaid?: (r: PaidReceipt) => void,
): Promise<Response> {
  const first = await fetch(input, init);
  if (first.status !== 402) return first;

  const body = (await first.json()) as { offer?: PaymentOffer };
  const offer = body.offer;
  if (!offer) throw new PaymentRefused("bad_offer", "402 without a payment offer");

  // Refuse to pay a contract we don't recognise. A compromised or lookalike
  // server can't redirect the agent's spend to its own vault.
  if (offer.contract.toLowerCase() !== config.vault.toLowerCase()) {
    throw new PaymentRefused("unknown_vault", `server asked for payment via ${offer.contract}, expected ${config.vault}`);
  }
  if (offer.chainId !== chain.id) {
    throw new PaymentRefused("wrong_chain", `offer is for chain ${offer.chainId}, we are on ${chain.id}`);
  }

  const amount = BigInt(offer.price);
  const { txHash, blockNumber } = await pay(offer.payee, amount, offer.requestId);
  onPaid?.({ txHash, blockNumber, amount, payee: offer.payee, requestId: offer.requestId });

  const headers = new Headers(init.headers);
  headers.set(PAYMENT_HEADER, txHash);
  const second = await fetch(input, { ...init, headers });

  if (second.status === 402 || second.status === 400) {
    const err = (await second.json().catch(() => ({}))) as { error?: string };
    throw new PaymentRefused("server_rejected", `paid ${txHash} but server refused: ${err.error ?? second.status}`);
  }
  return second;
}

async function pay(payee: Address, amount: bigint, requestId: Hex): Promise<{ txHash: Hex; blockNumber: bigint }> {
  const call = { account, address: config.vault, abi: vaultAbi, functionName: "pay", args: [payee, amount, requestId] } as const;
  let hash: Hex;
  try {
    // Simulate first (eth_call — the contract still does the refusing) so a
    // revert usually surfaces as a decoded error without spending gas.
    const { request } = await publicClient.simulateContract(call);
    hash = await walletClient.writeContract(request);
  } catch (e) {
    throw decodeRevert(e, amount);
  }

  const receipt = await publicClient.waitForTransactionReceipt({ hash, confirmations: 1 });
  if (receipt.status === "success") return { txHash: hash, blockNumber: receipt.blockNumber };

  // Mined revert (simulation ran against a node that was behind). A receipt
  // carries no revert data, so replay the call at that block to recover the
  // custom error name.
  try {
    await publicClient.simulateContract({ ...call, blockNumber: receipt.blockNumber });
  } catch (e) {
    const decoded = decodeRevert(e, amount);
    throw new PaymentRefused(decoded.code, `${decoded.message} (reverted on-chain, tx ${hash})`, decoded.detail);
  }
  throw new PaymentRefused("tx_reverted", `pay() reverted on-chain (tx ${hash})`);
}

function decodeRevert(e: unknown, amount: bigint): PaymentRefused {
  if (e instanceof BaseError) {
    const revert = e.walk((err) => err instanceof ContractFunctionRevertedError);
    if (revert instanceof ContractFunctionRevertedError) {
      const name = revert.data?.errorName ?? "UnknownRevert";
      const human = REVERT_MESSAGES[name] ?? revert.shortMessage;
      return new PaymentRefused(name, `vault refused ${fmtUsdc(amount)}: ${human}`, revert.data);
    }
    return new PaymentRefused("rpc_error", e.shortMessage, e);
  }
  return new PaymentRefused("unknown", String(e), e);
}

/**
 * Read the agent's remaining daily budget. Pass the block a payment landed in
 * to avoid reading a stale node on load-balanced public RPCs.
 */
export async function remainingToday(blockNumber?: bigint): Promise<bigint> {
  for (let attempt = 0; ; attempt++) {
    try {
      return await publicClient.readContract({
        address: config.vault,
        abi: vaultAbi,
        functionName: "remainingToday",
        args: [config.agent],
        blockNumber,
      });
    } catch (e) {
      if (attempt >= 4) throw e;
      await new Promise((r) => setTimeout(r, 400)); // node hasn't seen that block yet
    }
  }
}
