#!/usr/bin/env node
// consort: convert scanner-native JSON (trivy fs / SonarQube web API) into the
// shared findings shape (schemas/findings.schema.json), one finding per defect.
// Titles carry the scanner name so provenance survives merging with model findings.
//
// Usage: scan-to-findings.mjs trivy <trivy.json>
//        scan-to-findings.mjs sonar <issues.json> [hotspots.json] [projectKey]
import { readFileSync } from 'node:fs';

const [kind, ...files] = process.argv.slice(2);
if (!kind || !files[0]) {
  console.error('usage: scan-to-findings.mjs trivy <trivy.json> | sonar <issues.json> [hotspots.json] [projectKey]');
  process.exit(2);
}

// Malformed primary input is a FAILED conversion, never a clean empty result —
// truncated JSON or a proxy's HTML error page must not read as "no findings".
const load = (p) => {
  try { return JSON.parse(readFileSync(p, 'utf8')); }
  catch (e) { console.error(`scan-to-findings: cannot parse ${p}: ${e.message}`); process.exit(3); }
};
const loadOptional = (p) => { try { return JSON.parse(readFileSync(p, 'utf8')); } catch { return null; } };
const clip = (s, n = 600) => (s ?? '').replace(/\s+/g, ' ').trim().slice(0, n) || 'no description provided by scanner';
// trivy severities and Sonar impact severities (BLOCKER..INFO) share this map;
// legacy Sonar issue severities need the second one.
const tsev = (s) => ({ BLOCKER: 'critical', CRITICAL: 'critical', HIGH: 'high', MEDIUM: 'medium', LOW: 'low', INFO: 'low' }[s] ?? 'low');
const ssevLegacy = (s) => ({ BLOCKER: 'critical', CRITICAL: 'high', MAJOR: 'medium', MINOR: 'low', INFO: 'low' }[s] ?? 'medium');
// Sonar component keys are "<projectKey>:<repo/relative/path>". Strip the
// exact key when we have it — a Maven-style key like com.acme:app itself
// contains a colon, so splitting at the first colon corrupts the path.
const projectKey = files[2] ?? '';
const compPath = (c) => {
  c = c ?? '';
  if (projectKey && c.startsWith(projectKey + ':')) return c.slice(projectKey.length + 1);
  const i = c.indexOf(':');
  return i >= 0 ? c.slice(i + 1) : (c || 'unknown');
};
// One page of 500 is fetched; findings past it would silently vanish.
const warnTruncated = (doc, got, what) => {
  const total = doc?.paging?.total ?? doc?.total;
  if (Number.isFinite(total) && total > got) {
    console.error(`scan-to-findings: server reports ${total} ${what} but only ${got} fetched — findings TRUNCATED`);
  }
};

const findings = [];

if (kind === 'trivy') {
  for (const r of load(files[0])?.Results ?? []) {
    const target = r.Target || 'unknown';
    for (const v of r.Vulnerabilities ?? []) {
      findings.push({
        file: target, line: 1, severity: tsev(v.Severity),
        title: `trivy vuln: ${v.VulnerabilityID} in ${v.PkgName}@${v.InstalledVersion}${v.FixedVersion ? ` (fixed in ${v.FixedVersion})` : ' (no fix released)'}`,
        detail: `${clip(v.Title || v.Description)}${v.PrimaryURL ? ` — ${v.PrimaryURL}` : ''}`,
      });
    }
    // Never echo matched secret material; rule + location is enough to act on.
    for (const s of r.Secrets ?? []) {
      findings.push({
        file: target, line: s.StartLine || 1, severity: tsev(s.Severity),
        title: `trivy secret: ${s.Title || s.RuleID}`,
        detail: `Content matching secret rule ${s.RuleID} (${s.Category || 'uncategorized'}) at lines ${s.StartLine || '?'}-${s.EndLine || '?'}. If live: rotate the credential, then purge it from history; if a test fixture, mark it so the rule can be scoped.`,
      });
    }
    for (const m of r.Misconfigurations ?? []) {
      findings.push({
        file: target, line: m.CauseMetadata?.StartLine || 1, severity: tsev(m.Severity),
        title: `trivy misconfig: ${m.ID} — ${m.Title || 'misconfiguration'}`,
        detail: `${clip(m.Description)}${m.Resolution ? ` Resolution: ${clip(m.Resolution, 200)}` : ''}`,
      });
    }
  }
} else if (kind === 'sonar') {
  const issuesDoc = load(files[0]);
  warnTruncated(issuesDoc, (issuesDoc?.issues ?? []).length, 'unresolved issues');
  for (const i of issuesDoc?.issues ?? []) {
    const impact = (i.impacts ?? []).find((x) => x.softwareQuality === 'SECURITY') ?? (i.impacts ?? [])[0];
    findings.push({
      file: compPath(i.component), line: i.line ?? i.textRange?.startLine ?? 1,
      severity: impact ? tsev(impact.severity) : ssevLegacy(i.severity),
      title: `sonar: ${i.rule} — ${clip(i.message, 140)}`,
      detail: `${i.type || 'issue'} (${(i.impacts ?? []).map((x) => `${x.softwareQuality}:${x.severity}`).join(', ') || i.severity || 'unrated'}). ${clip(i.message)}`,
    });
  }
  const hotspotsDoc = files[1] ? loadOptional(files[1]) : null;
  warnTruncated(hotspotsDoc, (hotspotsDoc?.hotspots ?? []).length, 'TO_REVIEW hotspots');
  for (const h of hotspotsDoc?.hotspots ?? []) {
    findings.push({
      file: compPath(h.component), line: h.line ?? h.textRange?.startLine ?? 1,
      severity: tsev(h.vulnerabilityProbability) === 'critical' ? 'high' : tsev(h.vulnerabilityProbability),
      title: `sonar hotspot: ${h.securityCategory || 'security'} — ${clip(h.message, 140)}`,
      detail: `Security hotspot awaiting review (vulnerability probability ${h.vulnerabilityProbability || 'unknown'}). A hotspot is a use of a sensitive API that needs a human/model reachability verdict, not an automatic defect. ${clip(h.message)}`,
    });
  }
} else {
  console.error(`scan-to-findings: unknown scanner kind '${kind}' (expected trivy|sonar)`);
  process.exit(2);
}

console.log(JSON.stringify({ findings }, null, 1));
