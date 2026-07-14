#!/usr/bin/env node
// consort: merge two structured findings sets and surface the findings only ONE
// model caught — the cross-model heterogeneity signal. (SWE-chat 4-tool study:
// 93.4% of issues were caught by exactly one tool, so a single-model panel
// misses most of them.)
//
// Usage: node merge-findings.mjs <claude.json> <codex.json>
//   each file: {"findings":[{file,line,severity,title,detail}, ...]}
import { readFileSync } from 'node:fs';

const [claudePath, codexPath] = process.argv.slice(2);
if (!claudePath || !codexPath) {
  console.error('usage: merge-findings.mjs <claude.json> <codex.json>');
  process.exit(2);
}

const load = (p) => {
  try { return JSON.parse(readFileSync(p, 'utf8')).findings ?? []; }
  catch { return []; }
};
const norm = (s) => (s ?? '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
const PROXIMITY = 5; // same file + lines within this many rows => the same finding

const claude = load(claudePath);
const codex = load(codexPath);

// Greedy pairwise match: a Claude finding and a Codex finding are "the same"
// when they sit in the same file within PROXIMITY lines. Bucketing by line would
// split findings that straddle a bucket boundary (e.g. line 42 vs 44).
const both = [], claudeOnly = [];
const codexMatched = new Array(codex.length).fill(false);
for (const cf of claude) {
  const j = codex.findIndex((xf, i) =>
    !codexMatched[i] &&
    norm(cf.file) === norm(xf.file) &&
    Math.abs((Number(cf.line) || 0) - (Number(xf.line) || 0)) <= PROXIMITY);
  if (j >= 0) { codexMatched[j] = true; both.push(cf); }
  else claudeOnly.push(cf);
}
const codexOnly = codex.filter((_, i) => !codexMatched[i]);

const rank = { critical: 0, high: 1, medium: 2, low: 3 };
const bySeverity = (a, b) => (rank[a.severity] ?? 9) - (rank[b.severity] ?? 9);
const fmt = (f) => `  [${f.severity}] ${f.file}:${f.line} — ${f.title}`;

const out = [];
out.push(`\n## Cross-model review (${claude.length} Claude + ${codex.length} Codex findings)\n`);
out.push(`### Both models agree (${both.length}) — highest confidence`);
both.sort(bySeverity).forEach((f) => out.push(fmt(f)));
out.push(`\n### Claude only (${claudeOnly.length}) — Codex did not catch`);
claudeOnly.sort(bySeverity).forEach((f) => out.push(fmt(f)));
out.push(`\n### Codex only (${codexOnly.length}) — Claude did not catch (the second-opinion payoff)`);
codexOnly.sort(bySeverity).forEach((f) => out.push(fmt(f)));
console.log(out.join('\n'));
