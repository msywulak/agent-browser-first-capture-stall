// Pool every run that recorded the ANGLE backend, and sort each capture by what
// was actually on the live Chrome command line rather than by which arm it was
// meant to be. "Effective" means the WebGPU preset's --use-angle=vulkan was on
// the command line and no --use-angle=swiftshader overrode it.
import { readFileSync } from "node:fs";

const FILES = [
  "data/webgpu-preset-ab.jsonl",
  "data/dev-shm-and-preset.jsonl",
  "data/preset-overridden.jsonl",
];
const STALL_MS = 3000;
// Field names differ between runs; accept either spelling.
const field = (line, ...names) => {
  for (const n of names) {
    const m = new RegExp(`"${n}":"([^"]*)"`, "i").exec(line);
    if (m) return m[1];
  }
  return undefined;
};

const effective = { n: 0, stalls: 0 };
const overridden = { n: 0, stalls: 0 };
for (const file of FILES) {
  for (const line of readFileSync(file, "utf8").split("\n").filter((l) => l.trim())) {
    const vulkan = field(line, "angleVulkan", "fAngleVulkan");
    const swiftshader = field(line, "angleSwift", "fAngleSwift");
    if (vulkan === undefined || swiftshader === undefined) continue;
    const bucket = vulkan === "yes" && swiftshader === "no" ? effective : overridden;
    bucket.n += 1;
    if (Number(/"shotMs":(\d+)/.exec(line)?.[1] ?? -1) >= STALL_MS) bucket.stalls += 1;
  }
}

const rate = (b) => b.stalls / b.n;
const p1 = rate(effective);
const p0 = rate(overridden);
const pooled = (effective.stalls + overridden.stalls) / (effective.n + overridden.n);
const se = Math.sqrt(pooled * (1 - pooled) * (1 / effective.n + 1 / overridden.n));
const z = (p0 - p1) / se;
// Abramowitz and Stegun 7.1.26, good to about 1e-7.
const erf = (x) => {
  const t = 1 / (1 + 0.3275911 * Math.abs(x));
  const y = 1 - ((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * Math.exp(-x * x);
  return x >= 0 ? y : -y;
};
const p = 2 * (1 - 0.5 * (1 + erf(Math.abs(z) / Math.SQRT2)));

console.log(`preset effective:  ${effective.stalls}/${effective.n} = ${(100 * p1).toFixed(0)}%`);
console.log(`preset overridden: ${overridden.stalls}/${overridden.n} = ${(100 * p0).toFixed(0)}%`);
console.log(`z = ${z.toFixed(2)}, two-sided p = ${p.toFixed(4)}`);
