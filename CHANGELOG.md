# Changelog

All notable changes to consort are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html) while
still in 0.x.

## [0.5.0] — 2026-09-01

### Added
- **Scanner tier: `scripts/consort-scan.sh` + `scripts/scan-to-findings.mjs`.**
  A model-free third voice for reviews: runs Trivy (dependency CVEs, leaked
  secrets, IaC misconfigurations) when on PATH, and SonarQube when a server is
  reachable (`SONAR_HOST_URL`/`SONAR_TOKEN` + repo `sonar-project.properties`,
  including the analysis CE-task poll and issue/hotspot fetch), converting
  native scanner output into the shared `findings.schema.json` shape. Every
  skipped or failed scanner is reported on stderr — a scan that ran nothing
  says so instead of passing as clean. Secret findings never echo the matched
  material. Motivation: rule-based scanners and cross-model panels catch
  near-disjoint defect sets, so the tiers compose rather than compete.
- Third built-in pack `rules/security-review.md`: pairs the scanner tier with
  the model-tier security checks a pattern-matcher cannot do (authorization
  scoping, injection at construction sites, trust-boundary shifts, secrets in
  motion, dangerous sinks, supply chain). Scanner findings are deterministic
  evidence; the model owes each one a reachability verdict. Findings outside
  the diff are pre-existing debt except live credentials and criticals in
  newly added dependencies, which always gate.
- New command `/consort:scan` — run the scanner tier standalone and triage.
- **Security side-agent: `agents/security-reviewer`.** A blind, security-only
  subagent the review loop spawns in parallel with the cross-vendor pass —
  non-inheriting by contract, security classes only, findings returned in the
  shared schema and presented as their own column. Covers the
  independent-context axis on the same-vendor side; it complements, never
  satisfies, the cross-vendor requirement.
- Review loop (skill + lifecycle phase 5) gained a scanner step; merged
  reviews now present a fourth column, **Scanners**, after the cross-model
  three.

## [0.4.0] — 2026-08-19

### Added
- Blast-surface steps 6-8: peer-concurrency sweep, destructive-action gate
  (identity, scope, bound, symmetry), fix-introduced-invariant propagation.
  Distilled from the bot-review rounds on
  [openai/codex-plugin-cc#660](https://github.com/openai/codex-plugin-cc/pull/660): the four
  lenses behind its P1s that the pack did not encode.
- Second built-in pack `rules/finding-discipline.md`: findings name their
  trigger, severity carries the consequence (MINOR/P2 may be acknowledged with
  rationale), rounds converge instead of enduring, and guard/teardown-touching
  fixes get one scoped fix pass (blast-surface 7-8 over the fix diff) before
  done. Same source: the round behaviors that made the upstream bot effective.
- **Built-in methodology packs.** The plugin now ships a `rules/` directory that
  `consort-review.sh` always injects ahead of org/repo packs, and the review
  skill instructs the Claude-side reviewer to apply the same files. First pack:
  `rules/blast-surface.md`, a mandatory consumer-sweep discipline (inventory
  changed lifecycles, grep their consumers repo-wide, hunt removed implicit
  behavior, check runtime contracts, run the test suite against a baseline).
  Motivated by a 4-round upstream review cycle on a broker-lifecycle fix where
  every escaped finding lived outside the diff, in consumers neither reviewer
  had enumerated.
- **Review loop: test-suite step.** Ad-hoc `/consort:review` now runs the
  project's own test suite and compares against a pre-change baseline; the full
  `/consort` lifecycle already ran the suite via `consort-gate.sh` (current
  tree only, no baseline), ad-hoc reviews silently skipped it entirely.

### Changed
- Pack-resolution docs distinguish org coding standards (stay in the org repo)
  from vendor-neutral review methodology (ships with the plugin).

### Fixed
- Whitespace-only diff check is linear again: `${DIFF//[[:space:]]/}` is
  quadratic in macOS's system bash 3.2 and spins for CPU-hours on a multi-KB
  diff; replaced with a `grep -q '[^[:space:]]'` probe.

## [0.3.1] — 2026-07-22

### Added
- **Default pack resolution.** When `CONSORT_RULE_PACKS` is unset, a repo-local
  `.claude/rules/` directory is used automatically — zero-config reviews in
  repos that vendor their rule packs.

## [0.3.0] — 2026-07-22

### Added
- **Pack-aware review: `CONSORT_RULE_PACKS`.** Colon-separated files/dirs of
  `.md`/`.mdc` rule packs are injected into the Codex reviewer prompt by
  `consort-review.sh`, and the review skill instructs the principal to read
  the same packs for its own pass — one written standard, two independent
  readings. Packs stay in the consuming org's standards repo; consort carries
  the mechanism, never the rubric. 64KB cap with a loud stderr warning on
  truncation.

## [0.2.0] — 2026-07-20

### Changed
- **Panel drafts now come from independent spawned agents rather than the
  pipeline principal.** In 0.1.0 the principal produced one panel draft
  and sol produced the other; the same context that would later
  synthesize the panel was already committed to one of the two positions.
  0.2.0 spawns both panel voices as fresh subagent runs, keeping the
  principal purely as the synthesizer. Removes the "principal grading its
  own homework" bias in blind-panel synthesis.
  ([12ae25b](https://github.com/siimvene/consort/commit/12ae25b))

## [0.1.0] — 2026-07-18

Initial marketplace release.

### Added
- Cross-vendor development lifecycle: interview → spec → plan → implement
  → review → gate, with blind panels at spec and review.
- Slash-command surface: `/consort:run`, `/consort:review`, `/consort:plan`.
- Pluggable Codex backend — auto-detect and use the official Codex
  Claude Code plugin runtime when installed
  (`scripts/codex-backend.sh`). Falls back to raw `codex exec` CLI.
  Override via `CONSORT_CODEX_BACKEND=exec|plugin`.
  ([d3c2077](https://github.com/siimvene/consort/commit/d3c2077))
- Schema-forced findings JSON; deterministic merge script
  (`scripts/merge-findings.mjs`).
- Model-free gate (`scripts/consort-gate.sh`) — tests green, non-test
  code touched, `test.sh` at repo root.
- State bus at `.consort/` — every phase artifact resumable from disk.
