import { readFileSync } from "node:fs";
const rows = readFileSync(process.argv[2], "utf8").split("\n").filter((l) => l.startsWith("{")).map((l) => JSON.parse(l));
const med = (a) => { if (!a.length) return "-"; const s = [...a].sort((x, y) => x - y); return s[Math.floor(s.length / 2)]; };
const rng = (a) => a.length ? `${Math.min(...a)}-${Math.max(...a)}` : "-";
const groups = {};
for (const r of rows) {
  const p = r.page;
  const stalled = r.shotMs > 3000;
  const key = `${r.arm} ${stalled ? "STALLED" : "fast"}`;
  const g = (groups[key] ??= { n: 0, bad: 0, hidden: 0, focusFalse: 0, rafMaxGap: [], rafFirst: [], rafBefore9s: [], fcp: [], fcpVsShotEnd: [], to0: [], load: [], shot: [], selfcheck: new Set() });
  g.n++; g.shot.push(r.shotMs);
  g.selfcheck.add(`headed=${r.headed} fix=${r.fixOnCmdline} preset=${r.preset}`);
  if (!p) { g.bad++; continue; }
  if (p.vis0 !== "visible" || p.ev.length || p.samples.some((s) => s[1] !== "v")) g.hidden++;
  if (!p.focus0) g.focusFalse++;
  let mx = 0; for (let i = 1; i < p.raf.length; i++) mx = Math.max(mx, p.raf[i] - p.raf[i - 1]);
  g.rafMaxGap.push(mx); g.rafFirst.push(p.raf[0] ?? -1); g.rafBefore9s.push(p.raf.filter((t) => t < 9000).length);
  const fcp = p.paint.find((e) => e[0] === "first-contentful-paint"); g.fcp.push(fcp ? fcp[1] : -1);
  // capture end relative to the page's time origin, to line FCP up with the capture returning
  if (fcp) g.fcpVsShotEnd.push(Math.round((r.shotStartUs / 1000 + r.shotMs) - (p.origin + fcp[1])));
  g.to0.push(p.to0); g.load.push(p.load);
}
for (const [k, g] of Object.entries(groups).sort()) {
  console.log(`${k.padEnd(26)} n=${String(g.n).padStart(2)} noPage=${g.bad} hiddenEver=${g.hidden} focusFalse=${g.focusFalse} shotMs med ${med(g.shot)} [${rng(g.shot)}]`);
  console.log(`   FCP ms med ${med(g.fcp)} [${rng(g.fcp)}]  captureEnd-FCP med ${med(g.fcpVsShotEnd)} [${rng(g.fcpVsShotEnd)}]  rAF first med ${med(g.rafFirst)}  rAF max gap med ${med(g.rafMaxGap)} [${rng(g.rafMaxGap)}]  rAF<9s med ${med(g.rafBefore9s)}  setTimeout0 med ${med(g.to0)} load med ${med(g.load)}`);
  console.log(`   selfcheck: ${[...g.selfcheck].join(" ; ")}`);
}
