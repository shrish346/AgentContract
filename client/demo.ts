/**
 * R6 demo: 20 sequential paid requests against a budget that permits 12.
 * Expected: 1–12 served, 13 refused by the contract, process exits 0.
 */
import { payingFetch, remainingToday, PaymentRefused } from "./payingFetch.js";
import { fmtUsdc } from "../shared/chain.js";
import { config } from "../shared/config.js";

const URL = `${config.serverUrl}/api/quote`;
const TOTAL = 20;

console.log(`agent ${config.agent}`);
console.log(`vault ${config.vault}`);
console.log(`budget remaining today: ${fmtUsdc(await remainingToday())}`);
console.log(`requesting ${URL} ×${TOTAL}\n`);

for (let i = 1; i <= TOTAL; i++) {
  const t0 = Date.now();
  try {
    let tx = "";
    let block: bigint | undefined;
    const res = await payingFetch(URL, {}, (r) => ((tx = r.txHash), (block = r.blockNumber)));
    const data = (await res.json()) as { symbol: string; price: string };
    const left = await remainingToday(block);
    console.log(
      `#${String(i).padStart(2)}  OK      ${data.symbol} ${data.price}  paid ${tx.slice(0, 10)}…  ` +
        `remaining ${fmtUsdc(left)}  (${Date.now() - t0}ms)`,
    );
  } catch (e) {
    if (e instanceof PaymentRefused) {
      const left = await remainingToday();
      console.log(`#${String(i).padStart(2)}  REFUSED ${e.code}: ${e.message}  remaining ${fmtUsdc(left)}`);
      console.log(`\nstopping: payment refused, not retrying.`);
      process.exit(0);
    }
    console.error(`#${i}  ERROR`, e);
    process.exit(1);
  }
}

console.log(`\nall ${TOTAL} requests succeeded — budget was not the binding constraint.`);
