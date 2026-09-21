/**
 * Adversarial checks against a running paywall server. Each case is a way a
 * dishonest agent or third party might try to get served without paying the
 * real vault. All must be refused.
 *
 *   npm run attacks
 *
 * Uses OWNER_PRIVATE_KEY as the "attacker" purely because it has gas.
 */
import { createWalletClient, http, type Abi, type Address, type Hex, parseAbi } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { readFileSync } from "node:fs";
import { chain, publicClient, vaultAbi } from "../shared/chain.js";
import { config } from "../shared/config.js";

const S = config.serverUrl;
const attacker = privateKeyToAccount(process.env.OWNER_PRIVATE_KEY as Hex);
const agent = privateKeyToAccount(config.agentKey());
const wallet = (a: typeof attacker) => createWalletClient({ account: a, chain, transport: http(config.rpcUrl) });

async function offer(path: string) {
  const r = await fetch(`${S}${path}`);
  return ((await r.json()) as { offer: { requestId: Hex } }).offer.requestId;
}
async function present(path: string, tx: string) {
  const r = await fetch(`${S}${path}`, { headers: { "x-payment-tx": tx } });
  const body = (await r.json()) as { error?: string; symbol?: string; tier?: string };
  return `${r.status} ${body.error ?? body.symbol ?? body.tier}`;
}
async function send(a: typeof attacker, address: Address, functionName: string, args: unknown[], abi: Abi = vaultAbi) {
  // explicit gas: skip eth_estimateGas, which may hit a lagging public-RPC node
  const hash = await wallet(a).writeContract({ address, abi, functionName, args, gas: 200_000n } as never);
  const rc = await publicClient.waitForTransactionReceipt({ hash, confirmations: 1 });
  return { hash, status: rc.status };
}
const check = (name: string, got: string, want: string) =>
  console.log(`${got.startsWith(want) ? "PASS" : "FAIL"}  ${name.padEnd(46)} -> ${got}`);

// ---- 1. legit payment, then cross-path, then replay ------------------------
const rid = await offer("/api/quote");
const legit = await send(agent, config.vault, "pay", [config.payee, config.price, rid]);
check("cross-path: /api/quote receipt on /api/premium", await present("/api/premium", legit.hash), "402 requestId was issued for a different path");
check("correct path served once", await present("/api/quote", legit.hash), "200");
check("replay of redeemed receipt", await present("/api/quote", legit.hash), "402 payment already redeemed");

// ---- 2. tx from real vault that is not a payment --------------------------
const admin = await send(attacker, config.vault, "setPayee", [config.payee, true]);
check("real-vault tx with no Paid event", await present("/api/quote", admin.hash), "402 no Paid event");

// ---- 3. lookalike vault emitting a genuine Paid event ----------------------
const artifact = JSON.parse(readFileSync("contracts/out/AgentBudget.sol/AgentBudget.json", "utf8"));
const deployHash = await wallet(attacker).deployContract({ abi: vaultAbi, bytecode: artifact.bytecode.object, args: [config.usdc] });
const fake = (await publicClient.waitForTransactionReceipt({ hash: deployHash })).contractAddress!;
const usdcAbi = parseAbi(["function mint(address,uint256)"]);
await send(attacker, config.usdc, "mint", [fake, config.price], usdcAbi);
await send(attacker, fake, "setPolicy", [attacker.address, config.price, config.price]);
await send(attacker, fake, "setPayee", [config.payee, true]);
const rid2 = await offer("/api/quote");
const fakePay = await send(attacker, fake, "pay", [config.payee, config.price, rid2]);
check(`lookalike vault ${fake.slice(0, 10)}… Paid event`, await present("/api/quote", fakePay.hash), "402 no Paid event");

// ---- 4. junk ----------------------------------------------------------------
check("malformed header", await present("/api/quote", "0xdeadbeef"), "400");
check("unknown tx hash", await present("/api/quote", "0x" + "11".repeat(32)), "402 transaction not found");
