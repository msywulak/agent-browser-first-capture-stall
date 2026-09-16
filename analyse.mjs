// Summarise any of the data/*.jsonl files: stall rate and median per arm.
// Usage: node analyse.mjs data/capture-ordinal.jsonl [groupKey ...]
import { readFileSync } from "node:fs";

const STALL_MS = 3000;
const [file, ...groupKeys] = process.argv.slice(2);
if (!file) {
  console.error("usage: node analyse.mjs <file.jsonl> [groupKey ...]");
  process.exit(2);
}

const field = (line, key) => new RegExp(`"${key}":"?([^",}]*)"?`).exec(line)?.[1] ?? "";
const lines = readFileSync(file, "utf8").split("\n").filter((l) => l.trim());
const keys = groupKeys.length > 0 ? groupKeys : ["arm"];

const groups = new Map();
for (const line of lines) {
  const name = keys.map((k) => `${k}=${field(line, k)}`).join(" ");
  if (!groups.has(name)) groups.set(name, []);
  groups.get(name).push(Number(field(line, "shotMs")));
}

const median = (xs) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)];

console.log(`${lines.length} samples from ${file}\n`);
console.log("group".padEnd(38) + "  n  stalls   rate   median   stalled range");
for (const [name, xs] of groups) {
  const stalled = xs.filter((x) => x >= STALL_MS);
  const rate = `${((100 * stalled.length) / xs.length).toFixed(0)}%`;
  const range = stalled.length > 0 ? `${Math.min(...stalled)}..${Math.max(...stalled)} ms` : "-";
  console.log(
    name.padEnd(38) +
      String(xs.length).padStart(3) +
      String(stalled.length).padStart(8) +
      rate.padStart(7) +
      `${median(xs)} ms`.padStart(9) +
      "   " + range,
  );
}
