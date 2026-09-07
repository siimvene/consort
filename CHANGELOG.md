# Changelog

All notable changes to consort are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html) while
still in 0.x.

## [0.7.1] — 2026-09-07

### Fixed
- **Gemini cli transport ran a different model than asked.** gemini-cli
  (0.58.0, Vertex auth) treats any model id ending in `flash` as its flash
  alias and, with its 3.5-flash GA flag on, replaces it with its own default:
  `CONSORT_GEMINI_MODEL=gemini-3.8-flash` reviewed as gemini-3.5-flash and only
  the CLI's session log said so. The transport now runs every cli call with the
  CLI's experimental `dynamicModelConfiguration` resolver (passes unknown ids
  through untouched), enabled through a throwaway system settings file via
  `GEMINI_CLI_SYSTEM_SETTINGS_PATH` and layered over any real system settings —
  user and workspace settings are not touched. Every cli call and probe also
  runs with `--output-format json` and is checked against the envelope's
  `stats.models`: a run served by anything but the requested model is
  discarded as a failed call (empty result, exit 3 from `consort-review.sh`),
  never reported as a verdict. The same envelope yields one stderr line of
  evidence per call — tool calls, input/cached/thought/output tokens — so
  "did the reviewer really run, and did it read the repo" no longer needs the
  session log. Measured after the fix on the 25-file kvart PR #18 pre-fix
  diff: gemini-3.8-flash 496 s, 66 tool calls, 10.4M input tokens (9.7M
  cached); gemini-3.1-pro-preview 382 s, 36 tool calls.
  Hardened by the blind security pass before release: the throwaway settings
  live in an owner-only temp *directory* (the CLI derives its system-defaults
  path from the settings file's directory, so a bare file in `$TMPDIR` would
  have had it load a `/tmp/system-defaults.json` any local user could
  pre-create) with `GEMINI_CLI_SYSTEM_DEFAULTS_PATH` pinned to the real
  location; the real system settings are copied JSONC-tolerantly and the call
  fails closed if they exist but cannot be read or parsed; the served-model
  check requires the requested model to be the only one with main-role turns,
  so a mid-run fallback is discarded too; the temp directory is removed on
  Ctrl-C, timeout kill and `set -e` alike.

## [0.7.0] — 2026-09-07

### Changed
- **Codex exec transport runs read-only calls with `--ignore-user-config`**,
  reasoning effort pinned via `CONSORT_CODEX_REASONING` (default `high`). The
  reviewer no longer inherits `~/.codex/config.toml` plugins, plugin hooks,
  MCP servers or `developer_instructions`. Measured on a 25-file diff: a stock
  config whose oh-my-codex prompt hook matched "parallel mode" inside a rule
  pack fanned the review into three subagents and re-prompted from its Stop
  hook — 10.7M input tokens, 909 s; the bypass reviewed the same diff in 2.46M
  tokens, 495 s, with the same real findings. Workspace-write (delegation)
  keeps the user config, where sandbox narrowing and approval policy live;
  `CONSORT_CODEX_USER_CONFIG=1` keeps it for read-only calls too. A CLI
  without the flag falls back to the stock config with a stderr warning.
  (Gate: a free-form `CONSORT_CODEX_ARGS` passthrough was dropped before
  release — env-supplied argv after `-s` could have revoked the sandbox.)

### Added
- **Opt-in diff path excludes in `consort-review.sh`** (`CONSORT_DIFF_EXCLUDE`,
  colon-separated git pathspec globs matched from the repo root) for repos
  that commit generated artefacts. Nothing is excluded by default: lockfiles
  stay in, as the supply-chain rule requires. Excluded paths are listed on
  stderr and handed to the reviewer as fenced data; an all-excluded diff
  exits 4 instead of passing as clean. The diff is now taken from the repo
  root (`:/`) regardless of the caller's cwd.
- `CONSORT_GEMINI_STDERR`: file to append the Gemini CLI's stderr to
  (created owner-only; dropped by default).

### Fixed
- **Gemini cli transport reviewed diff-only.** Headless `gemini` made zero
  tool calls in every review run (three measured), so the "repo-reading"
  transport could not do the caller sweeps the rule packs ask for. The prompt
  now orders it to read every touched file and sweep callers, consumers,
  schedulers and docs of every removed symbol before answering; runs after the
  fix made 25–34 tool calls.
- **Gemini cli transport `@` expansion.** The CLI's `@file` expander
  (`(?<!\\)@` + path chars) read a unified diff's `@@` hunk headers as file
  references and injected unrelated repo files into the prompt. Every `@` in
  the prompt is now backslash-escaped, the CLI's own escape, which headless
  mode passes through as literal text.
- **Gemini api probe false negative.** `consort_gemini_probe` capped output at
  16 tokens, which a thinking model spends on thoughts (`finishReason:
  MAX_TOKENS`, empty text), so a live backend read as dead. Cap raised to 256
  and any candidate with a `finishReason` now counts as alive — the probe
  proves reachability, auth and quota, nothing more.

## [0.6.0] — 2026-09-04

### Added
- **Gemini backend — a first-class cross-vendor implementer/reviewer peer to
  Codex, chosen at will with `CONSORT_BACKEND=codex|gemini`.** Reaches Google's
  Gemini on Vertex AI via ADC (`gcloud`/WIF), no API key — usable where org
  policy disallows keys. Two transports (`CONSORT_GEMINI_TRANSPORT=cli|api`):
  the `gemini` CLI (`@google/gemini-cli`) run in the workdir for full parity —
  repo-wide sweeps in review, file edits in workspace-write (delegation) — and a
  stdlib Vertex `generateContent` companion (`gemini-companion.py`) as a
  diff-only, read-only CI fallback. Config: `CONSORT_GEMINI_MODEL` (default
  `gemini-3.1-pro-preview`), `CONSORT_GEMINI_LOCATION` (`global`; `europe-west4`
  for EU residency), `CONSORT_GCP_PROJECT`. A `consort_gemini_probe` gives the
  cheap liveness round-trip the honesty rules ask for.
- **`scripts/consort-backend.sh` — backend dispatcher.** The single entry point
  the caller scripts source; forwards `consort_impl_call` / `consort_backend` /
  `consort_impl_model` / `consort_impl_probe` to the selected backend. Codex and
  Gemini keep their own `consort_<backend>_*` modules.

### Changed
- `consort-review.sh`, `consort-consult.sh`, `consort-delegate.sh` now source the
  dispatcher and call `consort_impl_call` instead of `consort_codex_call`
  directly, so every path (review, consult, delegate) honors `CONSORT_BACKEND`.
  Default behavior (Codex) is unchanged.

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
