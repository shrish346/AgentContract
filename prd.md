# PRD — AgentBudget v0

**Status:** ready to build · **Scope:** one night · **Network:** Base Sepolia only

---

## Problem statement

Autonomous agents can now pay for services without a human in the loop. The
payment rails exist and are institutionally backed, but the controls around them
do not. An agent with a funded wallet can drain it in minutes through a bad loop,
a prompt injection, or a leaked key, and the operator finds out afterward by
reading a block explorer.

Traditional payment controls do not transfer. Cards rely on chargebacks, fraud
review, and a human present at purchase. None of those exist when the buyer is
software making thousands of sub-cent payments per hour.

The cost of not solving this is that operators either do not deploy paying
agents at all, or they deploy them with an unbounded wallet and absorb the risk
quietly.

## Goals

1. An agent can pay for an HTTP resource without any human interaction.
2. A spending limit set by the operator is enforced where the agent cannot reach
   it, and holds even if the agent's key is fully compromised.
3. A denied payment produces a clear, actionable signal to the agent rather than
   a crash or a retry loop.
4. The entire flow is demonstrable end to end from one terminal command.

## Non-goals

| Not doing                    | Why                                                                  |
| ---------------------------- | -------------------------------------------------------------------- |
| Mainnet deployment           | Unaudited contract holding real funds is a liability, not a demo     |
| Session keys / ERC-4337      | Meaningful only once policy delegation is needed; v1 concern         |
| x402 facilitator integration | The payment handshake is not the contribution; policy enforcement is |
| Multi-agent shared budgets   | Requires a coordinator service; changes the architecture             |
| A real LLM agent             | Adds nondeterminism and API cost while proving nothing extra         |
| Dashboard / analytics UI     | Terminal output demonstrates enforcement adequately                  |
| Persistent offer storage     | In-process maps are correct for single-replica v0                    |

## Users

**Operator** — funds the vault, sets policy, needs confidence the agent cannot
exceed it. This is the persona the product exists for.

**Agent** — consumes paid APIs, holds a key, holds no funds. A non-human user
whose failure modes (looping, injection, compromise) are the threat model.

**Service provider** — sells data per request, needs to verify payment before
serving and not be fooled by a replayed or spoofed receipt.

## User stories

- As an operator, I want to set a daily spend cap per agent so that a runaway
  loop costs me a bounded amount.
- As an operator, I want the agent to hold a key rather than funds so that key
  compromise is capped at the daily limit rather than the vault balance.
- As an operator, I want to restrict which addresses an agent may pay so that a
  prompt injection cannot redirect payment to an attacker.
- As an agent, I want a readable error when a payment is refused so that I can
  stop or choose a cheaper path instead of retrying forever.
- As a service provider, I want to verify a payment is for this specific request
  so that a receipt for a cheap endpoint cannot unlock an expensive one.
- As a service provider, I want a redeemed receipt to be single-use so that one
  payment cannot be replayed for unlimited responses.

## Requirements

### P0 — must ship tonight

**R1. Policy vault contract**

Owner-only `setPolicy`, `setPayee`, `revokeAgent`, `withdraw`. Agent-callable
`pay(payee, amount, requestId)` enforcing: agent active, payee allowlisted,
`requestId` unused, amount within per-call ceiling, amount within remaining
daily allowance. Daily counter resets on UTC day boundary. Emits `Paid` on
success.

- [ ] Given an active agent under both limits, when it calls `pay`, then USDC
      moves to the payee and `Paid` is emitted
- [ ] Given an amount above `perCallMax`, when the agent calls `pay`, then it
      reverts with `OverPerCallLimit` and no funds move
- [ ] Given prior spend that leaves less than the requested amount, when the
      agent calls `pay`, then it reverts with `OverDailyLimit`
- [ ] Given a warp past a UTC day boundary, when the agent calls `pay`, then the
      daily counter has reset
- [ ] Given a non-owner caller, when `setPolicy` is called, then it reverts with
      `NotOwner`
- [ ] Given a previously used `requestId`, when `pay` is called again with it,
      then it reverts with `DuplicateRequest`

**R2. Test token**

`MockUSDC`, ERC-20, **6 decimals**, public `mint`. Exists to remove the faucet
as a dependency.

- [ ] `decimals()` returns 6

**R3. Deployment**

Script deploying both contracts, funding the vault, setting one agent policy and
one allowlisted payee. Addresses written to `.env`.

- [ ] Given a completed deploy, when `remainingToday(agent)` is queried via
      `cast`, then it returns the configured `dailyMax`

**R4. Paywall middleware**

Hono middleware. Unpaid request returns 402 with a payment offer containing
price, payee, contract, and a fresh `requestId` bound to the request path.
Paid retry verifies the referenced transaction: it succeeded, the `Paid` log
originated from the vault address, payee matches, amount covers the price, the
`requestId` was issued for this path, the offer has not expired, and the
transaction has not previously been redeemed.

- [ ] Given no payment header, when a paid route is requested, then a 402 with a
      `requestId` is returned
- [ ] Given a valid receipt, when the request is retried, then the resource is
      served
- [ ] Given a receipt already redeemed once, when it is presented again, then the
      request is refused
- [ ] Given a `Paid` event from a contract other than the vault, when it is
      presented, then the request is refused
- [ ] Given a receipt for a different path's `requestId`, when it is presented,
      then the request is refused
- [ ] Given any refusal, then a structured denial line is logged server-side

**R5. Paying client**

`payingFetch` wrapping `fetch`: on 402, pay via the vault, await the receipt,
retry with the transaction hash attached. Payment lives in the transport layer
and is never exposed as a callable tool.

- [ ] Given a 402 response, when `payingFetch` is called, then it pays and
      returns the resource transparently
- [ ] Given a revert, when the error surfaces, then it is decoded into a readable
      message naming the violated limit
- [ ] Given a refusal, then the client exits rather than retrying

**R6. Demo**

One command runs 20 sequential requests against a budget permitting 12. Each
attempt logs outcome and remaining budget. Exits cleanly on first refusal.

- [ ] Requests 1–12 succeed, request 13 is refused, process exits 0

**R7. README**

Two-sentence description, architecture summary, explicit threat model, pasted
demo output, testnet-and-unaudited disclaimer.

### P1 — next few weeks

- Redis-backed offers and redemption set (survives restart, works across replicas)
- Session keys so policy can be delegated and revoked without an owner transaction
- Real x402 facilitator integration replacing the bespoke handshake
- Tool-calling LLM agent client with read-only budget awareness injected as context
- Spend dashboard reading `Paid` and `PolicySet` logs

### P2 — design for, do not build

- Multiple agents sharing one vault via a local payment broker, each retaining
  its own key so per-agent caps remain enforceable
- Per-payee and per-category sublimits
- Anomaly detection on spend patterns
- Mainnet deployment behind an audit

## Success metrics

**Tonight (binary):** the demo runs end to end and request 13 is refused by the
contract, not by client-side logic. If the refusal comes from TypeScript, the
project has failed its own thesis.

**This month:** the repo can be walked through in an interview without hedging.
Specifically, able to explain why policy is on-chain rather than in Postgres, why
payment is transport-layer rather than a tool, and why denial logging is
off-chain.

## Technical constraints

- Solidity ^0.8.24, Foundry. TypeScript, viem, Hono, tsx.
- Base Sepolia only. Pin all dependency versions.
- Contracts are immutable once deployed — tests pass before any deploy.

## Open questions

- **Engineering, non-blocking:** should the daily window be a UTC day boundary or
  a rolling 24-hour window? UTC is simpler and shipping tonight; rolling is more
  intuitive for operators. Revisit in P1.
- **Engineering, non-blocking:** should the server accept one confirmation or
  wait for finality? v0 accepts one confirmation deliberately; document the
  tradeoff rather than resolving it.
- **Design, non-blocking:** what should an agent see when refused — the remaining
  budget, or only the refusal? Exposing remaining budget is useful context but
  leaks operator policy into the model's context window.

## Working agreement for this session

1. `AgentBudget.sol` and `paywall.ts` are reference implementations. Fix bugs,
   do not restructure.
2. Build in requirement order: R1 → R2 → R3 → R4 → R5 → R6 → R7.
3. Run `forge test` after every contract edit.
4. Stop after each requirement for review.
5. Commit per requirement with a real message.
6. Build nothing in the non-goals table.
