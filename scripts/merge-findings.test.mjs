// node scripts/merge-findings.test.mjs — pins the N-way merge: clustering by
// file+proximity across any number of reviewers, one-finding-per-set-per-
// cluster, representative severity, label syntax, and the NO RESULT contract
// (an empty/missing/non-array file is a failed leg, exit 3, never clean).
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const here = dirname(fileURLToPath(import.meta.url));
const merge = join(here, 'merge-findings.mjs');
const base = mkdtempSync(join(tmpdir(), 'merge-findings-'));
const F = (file, line, severity, title) => ({ file, line, severity, title, detail: 'd' });
const write = (name, findings) => {
  const p = join(base, name);
  writeFileSync(p, findings === undefined ? '' : JSON.stringify({ findings }));
  return p;
};
const run = (...a) => spawnSync(process.execPath, [merge, ...a], { encoding: 'utf8' });
let fails = 0;
function expect(name, cond, extra = '') {
  if (!cond) fails++;
  console.log(`${cond ? 'ok  ' : 'FAIL'} ${name}${extra ? ' — ' + extra : ''}`);
}
const section = (out, title) => {
  const i = out.indexOf(`### ${title}`);
  if (i < 0) return null;
  const j = out.indexOf('\n###', i + 1);
  return out.slice(i, j < 0 ? undefined : j);
};

// 1. two-way parity with the old contract
{
  const c = write('claude.json', [F('a.py', 10, 'high', 'A'), F('b.py', 5, 'low', 'B')]);
  const x = write('codex.json', [F('a.py', 14, 'medium', 'A again'), F('c.py', 1, 'critical', 'C')]);
  const r = run(c, x);
  expect('2-way: exit 0', r.status === 0, r.stderr);
  expect('2-way: header counts', r.stdout.includes('(2 claude + 2 codex findings)'));
  const both = section(r.stdout, 'Caught by more than one reviewer (1)');
  expect('2-way: proximity 4 lines clusters', !!both && both.includes('a.py:10') && both.includes('[claude+codex]'));
  expect('2-way: representative is the more severe member', !!both && both.includes('[high] a.py:10 — A'));
  expect('2-way: codex only', (section(r.stdout, 'codex only (1)') ?? '').includes('c.py:1'));
  expect('2-way: claude only', (section(r.stdout, 'claude only (1)') ?? '').includes('b.py:5'));
}
// 2. proximity boundary: 5 apart clusters, 6 apart does not
{
  const c = write('claude.json', [F('a.py', 10, 'low', 'A')]);
  const x = write('five.json', [F('a.py', 15, 'low', 'X')]);
  const y = write('six.json', [F('a.py', 16, 'low', 'X')]);
  expect('proximity 5 clusters', run(c, x).stdout.includes('Caught by more than one reviewer (1)'));
  expect('proximity 6 does not', run(c, y).stdout.includes('Caught by more than one reviewer (0)'));
}
// 3. three-way: all agree, pairwise, and each-only; one per set per cluster
{
  const c = write('claude.json', [F('a.py', 10, 'medium', 'A'), F('z.py', 1, 'low', 'Z')]);
  const x = write('codex.json', [F('a.py', 11, 'high', 'A'), F('b.py', 20, 'high', 'B'), F('a.py', 12, 'low', 'A dup')]);
  const p = write('pi-google-vertex.json', [F('a.py', 9, 'critical', 'A'), F('b.py', 22, 'medium', 'B'), F('q.py', 3, 'low', 'Q')]);
  const r = run(c, x, p);
  expect('3-way: exit 0', r.status === 0, r.stderr);
  expect('3-way: header', r.stdout.includes('(2 claude + 3 codex + 3 pi-google-vertex findings)'));
  const both = section(r.stdout, 'Caught by more than one reviewer (2)');
  expect('3-way: all three on a.py, critical rep', !!both && both.includes('[critical] a.py:9 — A  [claude+codex+pi-google-vertex]'));
  expect('3-way: codex+pi on b.py', !!both && both.includes('b.py:20') && both.includes('[codex+pi-google-vertex]'));
  expect('3-way: agreement sorted before severity', !!both && both.indexOf('a.py:9') < both.indexOf('b.py:20'));
  expect('3-way: second codex finding in same spot is codex-only, not merged', (section(r.stdout, 'codex only (1)') ?? '').includes('a.py:12'));
  expect('3-way: pi only', (section(r.stdout, 'pi-google-vertex only (1)') ?? '').includes('q.py:3'));
  expect('3-way: claude only', (section(r.stdout, 'claude only (1)') ?? '').includes('z.py:1'));
  expect('3-way: reviewer-only sections come before principal-only', r.stdout.indexOf('### codex only') < r.stdout.indexOf('### claude only'));
}
// 4. label=path syntax
{
  const c = write('mine.json', [F('a.py', 1, 'low', 'A')]);
  const x = write('theirs.json', []);
  const r = run(`principal=${c}`, `gemini=${x}`);
  expect('label= syntax', r.status === 0 && r.stdout.includes('(1 principal + 0 gemini findings)') && r.stdout.includes('### principal only (1)'));
  expect('duplicate label rejected', run(`a=${c}`, `a=${x}`).status === 2);
  expect('one file rejected', run(c).status === 2);
}
// 5. NO RESULT: empty file, missing file, findings:null, {} — exit 3, loud, and the rest still reported
{
  const c = write('claude.json', [F('a.py', 1, 'low', 'A')]);
  const empty = write('codex.json');
  const r = run(c, empty);
  expect('empty reviewer file -> exit 3', r.status === 3, String(r.status));
  expect('empty reviewer file -> NO RESULT in report', r.stdout.includes('### codex: NO RESULT') && r.stdout.includes('DID NOT RUN'));
  expect('empty reviewer file -> principal still reported', r.stdout.includes('### claude only (1)'));
  expect('empty reviewer file -> no "codex only" section', !r.stdout.includes('### codex only'));
  expect('missing file -> exit 3', run(c, join(base, 'nope.json')).status === 3);
  writeFileSync(join(base, 'null.json'), '{"findings":null}');
  expect('findings:null -> exit 3', run(c, join(base, 'null.json')).status === 3);
  writeFileSync(join(base, 'obj.json'), '{}');
  expect('{} -> exit 3', run(c, join(base, 'obj.json')).status === 3);
  const good = write('pi.json', [F('a.py', 2, 'low', 'A')]);
  const r3 = run(c, empty, good);
  expect('3-way with one dead leg: others merge, still exit 3', r3.status === 3 && r3.stdout.includes('[claude+pi]'));
  expect('empty principal -> exit 3', run(empty, good).status === 3);
  expect('clean 0-finding file is NOT a no-result', run(c, write('zero.json', [])).status === 0);
}
rmSync(base, { recursive: true, force: true });
console.log(fails ? `${fails} FAILED` : 'all green');
process.exit(fails ? 1 : 0);
