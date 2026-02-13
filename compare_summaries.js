#!/usr/bin/env node
"use strict";

const fs = require("fs");

function parseArgs(argv) {
  const out = {};
  for (let i = 2; i < argv.length; i += 1) {
    const a = argv[i];
    if (!a.startsWith("--")) continue;
    const k = a.slice(2);
    const v = argv[i + 1];
    if (v === undefined || v.startsWith("--")) {
      out[k] = true;
      continue;
    }
    out[k] = v;
    i += 1;
  }
  return out;
}

function abs(x) {
  return x < 0 ? -x : x;
}

function parseCsv(filePath) {
  const txt = fs.readFileSync(filePath, "utf8");
  const lines = txt.split(/\r?\n/).filter((l) => l.trim() !== "");
  if (lines.length <= 1) return new Map();
  const map = new Map();
  for (let i = 1; i < lines.length; i += 1) {
    const cols = lines[i].split(",");
    if (cols.length < 5) continue;
    const rec = {
      test: cols[0],
      metric: cols[1],
      value: Number(cols[2]),
      unit: cols[3],
      better: cols[4],
    };
    if (!Number.isFinite(rec.value)) continue;
    const key = `${rec.test}::${rec.metric}`;
    map.set(key, rec);
  }
  return map;
}

function pad(v, n) {
  return String(v).padEnd(n, " ");
}

function fmtNum(v) {
  return Number(v).toFixed(3);
}

function main() {
  const args = parseArgs(process.argv);
  const baseline = args.baseline;
  const current = args.current;
  const warnPct = Number(args["warn-pct"] ?? 5);
  const failPct = Number(args["fail-pct"] ?? 10);

  if (!baseline || !current) {
    console.error("Uso: compare_summaries.js --baseline a.csv --current b.csv --warn-pct 5 --fail-pct 10");
    process.exit(2);
  }

  const baseMap = parseCsv(baseline);
  const curMap = parseCsv(current);

  let hasFail = false;
  const byTest = new Map();

  function pushRow(test, row) {
    if (!byTest.has(test)) byTest.set(test, []);
    byTest.get(test).push(row);
  }

  for (const [key, b] of baseMap.entries()) {
    const c = curMap.get(key);
    if (!c) {
      pushRow(b.test, `${pad("FAIL", 4)} | ${pad(b.metric, 42)} | baseline=${fmtNum(b.value)} ${b.unit} ; current=missing`);
      hasFail = true;
      continue;
    }

    if (b.unit !== c.unit || b.better !== c.better) {
      pushRow(b.test, `${pad("WARN", 4)} | ${pad(b.metric, 42)} | metadata changed (${b.unit}/${b.better} -> ${c.unit}/${c.better})`);
    }

    const delta = c.value - b.value;
    const pct = b.value === 0 ? (delta === 0 ? 0 : 100) : (delta / abs(b.value)) * 100;

    let status = "OK";
    const better = c.better || b.better;
    if (better === "higher") {
      if (pct <= -failPct) status = "FAIL";
      else if (pct <= -warnPct) status = "WARN";
    } else if (better === "lower") {
      if (pct >= failPct) status = "FAIL";
      else if (pct >= warnPct) status = "WARN";
    }

    const line = `${pad(status, 4)} | ${pad(b.metric, 42)} | ${fmtNum(b.value).padStart(10)} ${pad(b.unit, 7)} -> ${fmtNum(c.value).padStart(10)} ${pad(c.unit, 7)} | ${delta >= 0 ? "+" : ""}${fmtNum(delta)} (${pct >= 0 ? "+" : ""}${pct.toFixed(2)}%)`;
    pushRow(b.test, line);

    if (status === "FAIL") hasFail = true;
  }

  for (const [key, c] of curMap.entries()) {
    if (baseMap.has(key)) continue;
    pushRow(c.test, `${pad("INFO", 4)} | ${pad(c.metric, 42)} | baseline=missing ; current=${fmtNum(c.value)} ${c.unit}`);
  }

  const tests = Array.from(byTest.keys()).sort();
  for (const test of tests) {
    console.log(`## ${test}`);
    const rows = byTest.get(test).slice().sort((a, b) => a.localeCompare(b));
    for (const row of rows) {
      console.log(row);
    }
    console.log("");
  }

  process.exit(hasFail ? 1 : 0);
}

main();
