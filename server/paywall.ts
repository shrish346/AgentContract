/**
 * Hono paywall middleware.
 *
 * Unpaid request  -> 402 + offer { price, payee, contract, requestId, expiresAt }
 * Paid retry      -> header X-Payment-Tx: <hash>; we verify the on-chain receipt
 *                    and, if it checks out, redeem it and let the request through.
 *
 * Every refusal is logged server-side as one structured JSON line. Nothing here
 * enforces spend limits — that is the contract's job. This layer only answers
 * "did this exact request get paid for, exactly once, by the real vault?"
 */
import type { MiddlewareHandler } from "hono";
import { type Address, type Hex, isHex, parseEventLogs, toHex } from "viem";
import { randomBytes } from "node:crypto";
import { publicClient, vaultAbi } from "../shared/chain.js";

export type PaymentOffer = {
  price: string; // 6-decimal USDC units, as a decimal string
  payee: Address;
  contract: Address;
  requestId: Hex;
  expiresAt: number; // unix ms
  chainId: number;
};

type PendingOffer = { path: string; price: bigint; expiresAt: number };

export type PaywallOptions = {
  price: bigint;
  payee: Address;
  vault: Address;
  /** How long an offer stays valid. Default 5 min. */
  offerTtlMs?: number;
};

export const PAYMENT_HEADER = "x-payment-tx";

/**
 * In-process state. Correct for a single replica; P1 moves this to Redis.
 *  - offers:   requestId -> what it was issued for
 *  - redeemed: tx hashes that already unlocked a response
 */
const offers = new Map<Hex, PendingOffer>();
const redeemed = new Set<Hex>();

function deny(reason: string, extra: Record<string, unknown> = {}) {
  console.log(JSON.stringify({ level: "deny", reason, ...extra, at: new Date().toISOString() }));
}

export function paywall(opts: PaywallOptions): MiddlewareHandler {
  const ttl = opts.offerTtlMs ?? 5 * 60_000;

  return async (c, next) => {
    const path = c.req.path;
    const txHeader = c.req.header(PAYMENT_HEADER);

    // ---- no payment: issue an offer ------------------------------------
    if (!txHeader) {
      const requestId = toHex(randomBytes(32));
      const expiresAt = Date.now() + ttl;
      offers.set(requestId, { path, price: opts.price, expiresAt });

      const offer: PaymentOffer = {
        price: opts.price.toString(),
        payee: opts.payee,
        contract: opts.vault,
        requestId,
        expiresAt,
        chainId: publicClient.chain.id,
      };
      return c.json({ error: "payment required", offer }, 402);
    }

    // ---- payment presented: verify ----------------------------------------
    if (!isHex(txHeader) || txHeader.length !== 66) {
      deny("malformed_tx_hash", { path, tx: txHeader });
      return c.json({ error: "malformed payment header" }, 400);
    }
    const txHash = txHeader as Hex;

    if (redeemed.has(txHash)) {
      deny("already_redeemed", { path, txHash });
      return c.json({ error: "payment already redeemed" }, 402);
    }

    let receipt;
    try {
      receipt = await publicClient.getTransactionReceipt({ hash: txHash });
    } catch {
      deny("receipt_not_found", { path, txHash });
      return c.json({ error: "transaction not found or not yet mined" }, 402);
    }

    if (receipt.status !== "success") {
      deny("tx_reverted", { path, txHash });
      return c.json({ error: "transaction reverted" }, 402);
    }

    // Only trust Paid events emitted by *our* vault. A Paid log from any other
    // contract (someone deploying a lookalike) is filtered out here.
    const paidLogs = parseEventLogs({
      abi: vaultAbi,
      eventName: "Paid",
      logs: receipt.logs.filter((l) => l.address.toLowerCase() === opts.vault.toLowerCase()),
    });

    if (paidLogs.length === 0) {
      deny("no_paid_event_from_vault", { path, txHash, logAddresses: receipt.logs.map((l) => l.address) });
      return c.json({ error: "no Paid event from vault in transaction" }, 402);
    }
    const paid = paidLogs[0].args;

    if (paid.payee.toLowerCase() !== opts.payee.toLowerCase()) {
      deny("wrong_payee", { path, txHash, got: paid.payee, want: opts.payee });
      return c.json({ error: "payment went to a different payee" }, 402);
    }

    const offer = offers.get(paid.requestId);
    if (!offer) {
      deny("unknown_request_id", { path, txHash, requestId: paid.requestId });
      return c.json({ error: "requestId was not issued by this server" }, 402);
    }
    if (offer.path !== path) {
      deny("request_id_path_mismatch", { path, txHash, requestId: paid.requestId, issuedFor: offer.path });
      return c.json({ error: "requestId was issued for a different path" }, 402);
    }
    if (Date.now() > offer.expiresAt) {
      offers.delete(paid.requestId);
      deny("offer_expired", { path, txHash, requestId: paid.requestId });
      return c.json({ error: "offer expired" }, 402);
    }
    if (paid.amount < offer.price) {
      deny("underpaid", { path, txHash, got: paid.amount.toString(), want: offer.price.toString() });
      return c.json({ error: "amount does not cover price" }, 402);
    }

    // ---- accept: redeem exactly once -------------------------------------
    redeemed.add(txHash);
    offers.delete(paid.requestId);
    c.set("payment", { txHash, agent: paid.agent, amount: paid.amount, requestId: paid.requestId });
    await next();
  };
}
