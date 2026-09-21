# AgentBudget v0

On-chain spending policy for autonomous agents. An operator funds a vault
contract and sets per-agent limits; the agent holds a key but no funds, and
pays for HTTP resources through the vault. Limits are enforced by the contract,
not by client code. Full spec: `prd.md` — read it before doing anything.

**Thesis (do not violate):** request 13 in the demo must be refused by the
contract revert, not by TypeScript. If a limit is ever checked client-side
before the transaction is sent, the project has failed.

## Stack

- Contracts: Solidity ^0.8.24, Foundry (`forge`, `cast`, `anvil`). OpenZeppelin for ERC-20.
- Off-chain: TypeScript, viem, Hono, tsx. Node 25.
- Network: Base Sepolia only. Never mainnet.
- Pin every dependency version (no `^` in package.json, pin the OZ submodule/tag).

## Planned layout

```
contracts/            Foundry project
  src/AgentBudget.sol   policy vault (R1)
  src/MockUSDC.sol      6-decimal test token (R2)
  test/                 forge tests
  script/Deploy.s.sol   deploy + fund + set policy + set payee (R3)
server/
  paywall.ts            Hono 402 middleware (R4)
  index.ts              paid route(s)
client/
  payingFetch.ts        fetch wrapper that pays on 402 (R5)
  demo.ts               20-request demo (R6)
.env                    addresses written by deploy script (gitignored)
README.md               R7
```

## Plan of action

Build strictly in this order. Stop after each requirement for review. Commit
per requirement with a real message.

### 0. Prerequisites (before R1)
- Install Foundry (`curl -L https://foundry.paradigm.xyz | bash && foundryup`).
- `git init`, `.gitignore` (`.env`, `node_modules`, `out`, `cache`, `broadcast`).
- `forge init contracts --no-git`, install OpenZeppelin at a pinned tag.
- `npm init`, install viem / hono / @hono/node-server / tsx / typescript at pinned versions.
- Fund a deployer key with Base Sepolia ETH (faucet). No USDC faucet needed — MockUSDC handles it.

### R1. `AgentBudget.sol` — policy vault
- State: `owner`, `token` (immutable), per-agent `Policy { perCallMax, dailyMax, active }`,
  per-agent `spentToday` + `dayIndex` (`block.timestamp / 1 days`), `allowedPayee[addr]`,
  `usedRequestId[bytes32]`.
- Owner-only: `setPolicy(agent, perCallMax, dailyMax)`, `setPayee(addr, bool)`,
  `revokeAgent(agent)`, `withdraw(to, amount)`.
- Agent-callable `pay(payee, amount, requestId)` — check order: active → payee allowed →
  requestId unused → `amount <= perCallMax` → day rollover → `spent + amount <= dailyMax`.
  Then mark requestId, add to spent, `safeTransfer`, emit `Paid(agent, payee, amount, requestId)`.
- View `remainingToday(agent)` — must account for day rollover without writing state.
- Custom errors: `NotOwner`, `AgentInactive`, `PayeeNotAllowed`, `DuplicateRequest`,
  `OverPerCallLimit`, `OverDailyLimit`. Events: `Paid`, `PolicySet`, `PayeeSet`, `AgentRevoked`.
- Tests cover all six acceptance criteria in the PRD, including `vm.warp` across a UTC day.
- `forge test` after every contract edit.

### R2. `MockUSDC.sol`
- OZ ERC20, `decimals()` overridden to 6, public unrestricted `mint(to, amount)`.
- Test: `decimals() == 6`.

### R3. `Deploy.s.sol`
- Deploy MockUSDC, deploy AgentBudget(token), mint to vault, `setPolicy(agent, ...)`,
  `setPayee(payee, true)`. Write `VAULT_ADDRESS`, `USDC_ADDRESS`, `AGENT_ADDRESS`,
  `PAYEE_ADDRESS` to `.env`.
- Verify: `cast call $VAULT "remainingToday(address)" $AGENT` returns `dailyMax`.
- Tests must be green before this runs — contracts are immutable once deployed.

### R4. `paywall.ts` — Hono middleware
- No `X-Payment-Tx` header → 402 JSON `{ price, payee, contract, requestId, expiresAt }`.
  `requestId = keccak256(random)` stored in an in-process `Map<requestId, {path, price, expiresAt}>`.
- Paid retry: fetch receipt via viem, verify in order: `status == success` → a `Paid` log
  whose `address == VAULT` (decode with the vault ABI, ignore others) → `payee` matches →
  `amount >= price` → `requestId` exists in map and its `path == req.path` → not expired →
  tx hash not in redeemed `Set`. Any failure → 402/403 + one structured denial log line
  (`{ reason, requestId, txHash, path }`). Success → add to redeemed set, delete offer, `next()`.
- Accept one confirmation (documented tradeoff, see PRD open questions).
- In-process maps are intentional for v0 (non-goal: persistent storage).

### R5. `payingFetch.ts`
- `fetch` → if 402, parse offer, call `vault.pay(payee, price, requestId)` with the agent
  key via viem `walletClient`, `waitForTransactionReceipt`, retry with `X-Payment-Tx`.
- Decode reverts: use `ContractFunctionRevertedError` / `BaseError.walk` to map the custom
  error name to a human message ("Refused: daily limit exceeded"). Do not swallow it.
- On refusal: throw a typed `PaymentRefused` error. Never retry a refused payment.
- Payment is transport-layer. It is not a tool, not exported as a callable action.

### R6. `demo.ts`
- Loop 20 requests through `payingFetch`. After each, log outcome + `remainingToday`.
- Catch `PaymentRefused` → log it → `process.exit(0)`. Budget set so 12 succeed, 13 refused.
- Single entrypoint: `npm run demo` (starts server, runs client, or documents two terminals).

### R7. README
- Two-sentence description, architecture diagram (operator / vault / agent / server),
  explicit threat model (loop, injection, key compromise, receipt replay, receipt
  cross-path reuse, spoofed `Paid` event), pasted demo output, testnet + unaudited disclaimer.

## How we work

Claude writes the files; the user wants to be walked through each one so they
can explain it in an interview. For every file: write it, then give a short
explanation of the non-obvious decisions (why this check order, why this
storage layout, why custom errors) — not a line-by-line narration. Speed
matters; keep explanations tight.

## Rules for this repo

1. Build in requirement order R1 → R7. Don't start R(n+1) before R(n) is reviewed.
2. Run `forge test` after every contract edit. Tests green before any deploy.
3. Commit per requirement. Message says what and why, not "wip".
4. Build nothing from the PRD's non-goals table (no mainnet, no ERC-4337/session keys,
   no x402 facilitator, no shared budgets, no LLM agent, no UI, no persistence).
5. Once `AgentBudget.sol` and `paywall.ts` exist they are reference implementations:
   fix bugs, don't restructure.
6. No limit checks in TypeScript before sending a tx. The contract is the only enforcer.
7. Denial logging is off-chain (server). Policy is on-chain. Keep that split.

## Open questions (non-blocking, don't resolve tonight)

- UTC day boundary vs rolling 24h window — v0 uses UTC day. Revisit in P1.
- One confirmation vs finality — v0 accepts one. Document, don't resolve.
- Should the agent see remaining budget on refusal, or only the refusal? Demo logs
  remaining budget for the operator's benefit; whether to expose it to a model is P1.

## Status

- [ ] 0. Prerequisites (Foundry not yet installed)
- [ ] R1 Vault contract + tests
- [ ] R2 MockUSDC
- [ ] R3 Deploy script
- [ ] R4 Paywall middleware
- [ ] R5 payingFetch
- [ ] R6 Demo
- [ ] R7 README
