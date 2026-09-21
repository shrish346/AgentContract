import { Hono } from "hono";
import { serve } from "@hono/node-server";
import { config } from "../shared/config.js";
import { fmtUsdc } from "../shared/chain.js";
import { paywall } from "./paywall.js";

type Env = { Variables: { payment: { txHash: string; agent: string; amount: bigint; requestId: string } } };
const app = new Hono<Env>();

app.get("/", (c) => c.text("AgentBudget demo server. Paid route: GET /api/quote"));

// The paid resource. Price is enforced by paywall(); the handler never sees an
// unpaid request.
app.get("/api/quote", paywall({ price: config.price, payee: config.payee, vault: config.vault }), (c) => {
  const p = c.get("payment");
  console.log(JSON.stringify({ level: "serve", path: c.req.path, txHash: p.txHash, agent: p.agent, amount: p.amount.toString() }));
  return c.json({
    symbol: "ETH/USD",
    price: (3000 + Math.random() * 100).toFixed(2),
    asOf: new Date().toISOString(),
    paidBy: p.agent,
    tx: p.txHash,
  });
});

// Second paid route so a receipt for /api/quote cannot unlock this one.
app.get("/api/premium", paywall({ price: config.price, payee: config.payee, vault: config.vault }), (c) => {
  const p = c.get("payment");
  console.log(JSON.stringify({ level: "serve", path: c.req.path, txHash: p.txHash, agent: p.agent, amount: p.amount.toString() }));
  return c.json({ tier: "premium", secret: "the cake is a lie", paidBy: p.agent, tx: p.txHash });
});

serve({ fetch: app.fetch, port: config.port }, (info) => {
  console.log(`paywall server on http://localhost:${info.port}`);
  console.log(`  vault ${config.vault}  payee ${config.payee}  price ${fmtUsdc(config.price)}`);
});
