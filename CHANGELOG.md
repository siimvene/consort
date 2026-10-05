# Changelog

All notable changes to consort are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html) while
still in 0.x.

## [0.12.1] — 2026-10-06

### Fixed
- **A Pi review is no longer thrown away for one off-enum severity.** The Pi
  leg validated the model's final JSON against `findings.schema.json`, and a
  single `"severity": "major"` (Gemini writes these) failed the whole result,
  so the panel reported a FAILED leg and every finding in it was lost. The
  validator now normalises severities first: case-insensitive, with common
  synonyms mapped (`blocker`→critical; `major`/`serious`/`error`→high;
  `moderate`/`warning`→medium; `minor`/`info`/`nit`/`note`/`trivial`→low). An
  unknown value is raised to `high` for adjudication, with the original noted
  in the finding's `detail`, so it is never dropped and never downgraded. Each
  rewrite is logged on stderr. Any other schema violation (missing field,
  wrong type, `findings: null`) still fails the leg. New
  `scripts/pi-backend.test.sh` pins both sides.

## [0.12.0] — 2026-10-01

### Changed
- **Default Codex model is now `gpt-6.1-sol`** (was `gpt-5.6-sol`) for the
  implementer, the review/consult/delegate scripts, the panel's codex leg and
  the Pi `openai`/`openai-codex` provider default. Needs codex-cli >= 0.159.1,
  the first release whose model catalog carries GPT-6.1 Sol; older clients get
  a 400 ("model is not supported when using Codex with a ChatGPT account").
  Pin the old model with `CONSORT_IMPL_MODEL=gpt-5.6-sol` or a
  `codex:gpt-5.6-sol` panel spec.

## [0.11.0] — 2026-09-29

### Added
- **Codex account failover: `CONSORT_CODEX_HOMES`.** A `:`-separated list of
  `CODEX_HOME` directories, one per Codex account, tried in order. A call
  moves on only when codex reports a usage or rate limit in its own error
  events or stderr (the exec transport now runs `--json`); the transcript is
  never read for it. Any other failure stops the walk. `@default` and
  `@termscape` expand to the inherited home and to every Codex account
  Termscape (nodeterm) has signed in (system account, then
  `~/.nodeterm/cx/<sha256(userData\0id)[:16]>`). One stderr line per attempt
  names the home that ran. A home list forces the exec transport (the
  plugin broker is pinned to one account) and refuses an explicit
  `CONSORT_CODEX_BACKEND=plugin`. Delegation fails over only when the
  limited attempt did no work at all (no item in codex's event stream), so
  a half-applied edit or a leftover background process never reaches a
  second account. Keyring-backed logins (no `auth.json`) are recognised via
  `codex login status`. Only error events and a work-item count are kept
  from the stream; the transcript never touches disk. The Codex probe walks
  the same list. Tests: `scripts/codex-backend.test.sh` (stub codex).
- Hardened by the gate on this change (Codex, Gemini via Pi, blind security
  agent): the first cut fingerprinted the work tree with `git add -A` in a
  throwaway index, which ran the repo's `core.fsmonitor`, wrote untracked
  files into `.git/objects` and missed edits to ignored files; replaced by
  the no-work rule above. A malformed Termscape `settings.json` no longer
  echoes its offending line (it can hold an API key); a refused call clears
  a stale result file; the walk and the probe survive a caller's
  `set -euo pipefail` without `|| true`.

### Fixed
- `codex exec` calls without a payload and the Codex probe now read stdin
  from `/dev/null`; before, a call with no payload could sit on "Reading
  additional input from stdin..." when it inherited an open pipe that never
  closed (a harness or a background job).

## [0.10.0] — 2026-09-08

### Changed
- **The principal's review pass runs in a non-inheriting agent, not in the
  authoring session.** New `agents/code-reviewer` — same shape as the
  security side-agent: Read/Grep/Glob, no shell, fed the diff file, the pack
  paths and the test summary, returning findings JSON. It runs the
  blast-surface sweep with repo access and is the "Claude only" column of
  the merge. Why: a review pass is 30 to 40 tool calls, and every call
  re-reads the whole context it runs in. In an authoring session at 200k to
  400k tokens that pass alone cost more than every other leg combined, and
  it was the one leg nobody measured — the security side-agent reports ~110k
  tokens over 19 to 32 calls for its whole pass, the principal's had no
  boundary to report from. The review skill and `/consort:review` now have
  the session gather mechanical evidence (diff file, scanners, tests), spawn
  both agents and the panel in parallel, merge, verify and present; it no
  longer reads the packs or the diff into its own context.

### Added
- **`scripts/consort-test.sh [base]`** — blast-surface step 5 as a tool
  instead of a chore in the session. Runs the suite (`CONSORT_TEST_CMD`, or
  detected from `test.sh`, `package.json`, pytest markers, `go.mod`,
  `Cargo.toml`, a Makefile `test:` target) on head and in a detached
  worktree of the base ref (dependency dirs symlinked so a fresh checkout can
  start), normalises failure lines across pytest / jest / go / cargo / TAP,
  and prints ONE summary line plus the new failures (capped,
  `CONSORT_TEST_MAX_LINES`) and the run directory. Full logs and a
  `result.json` stay on disk for the code-reviewer agent. Exit 0 nothing
  new · 1 new failures, or a red head against a green baseline whose
  failures the parser could not read · 2 did not run (no command, bad ref,
  head timed out under `CONSORT_TEST_TIMEOUT`) · 3 head ran but the
  baseline could not — the last two are reported as such, never as green.
  Run directories are owner-only; `CONSORT_TEST_DIR` gets the panel's
  ownership and writability checks. Pinned by `consort-test.test.sh` (30
  checks: baseline diffing, no-baseline mode, log-on-disk output budget, the
  cap, the crash case, refusals, the parser).

## [0.9.1] — 2026-09-07

### Fixed
- **`merge-findings.mjs` clusters the same defect anchored on different
  files.** Two reviewers can pin one defect to two files — one on the script
  that fails to prune, the other on the unit file being deleted — and
  file+line clustering showed it as two "only" findings, understating
  agreement (measured on kvart PR #18: the panel's union was reported as
  1 agreed + 2 "only" where it was 2 agreed). A finding now also joins a
  cluster when its title names another member's file (last two path
  segments, or a bare basename of at least 8 characters, so `run.py` in a
  title is not a link); the detail is not used because it routinely lists
  neighbours, and word overlap was rejected because the real case shared one
  content word. Such clusters are tagged `cross-file`. One reviewer's two
  findings never merge, as before.
- Hardened by the gate on that change (Codex, Gemini via Pi, blind security
  agent): every member of a cluster is printed under its representative, so
  a cluster can no longer delete a reviewer's text from the report; the
  title match requires a whole path token (`subtasks/run.py` does not name
  `tasks/run.py`) and a key that looks like a file (an extension or a path,
  at least 8 characters — a one-word `file` such as `authorization` cannot
  act as a keyword magnet); files compare as paths, not through the
  punctuation-stripping normaliser (`src/foo-bar.js` and `src/foo/bar.js`
  are distinct); a finding that relates to several clusters merges them
  when they share no reviewer, so the outcome no longer depends on argument
  order, and prefers the cluster it names explicitly over the one it merely
  sits near when they cannot merge; reviewer file strings no longer appear
  in the tag; a set is capped at 500 findings with a loud stderr line.
  Second round (Codex, Gemini via Pi): path tokens are extracted from the
  title and matched as whole-segment suffixes of the other file's path (a
  full repo-relative path and a trailing period both work now); a bare
  basename shared by two different paths in the merge names nothing; a
  finding joins the largest compatible subset of its candidate clusters
  (no reviewer twice, span within the proximity even after a merge) rather
  than only the first, so non-disjoint candidates resolve the same way in
  any argument order; members keep arrival order through merges so the
  tie-break "earliest set" holds. Still greedy, by construction and now
  documented: one finding relating to two findings of the same reviewer
  joins the earlier; proximity grouping within a file follows arrival order.

## [0.9.0] — 2026-09-07

### Added
- **Review panel — several cross-vendor reviewers on every diff, chosen
  with `CONSORT_REVIEWERS`.** `scripts/consort-panel.sh [base]` runs
  `consort-review.sh` once per leg (`codex[:model]`, `gemini[:model]`,
  `pi[:provider[:model]]`; e.g. `codex,pi:google-vertex` = the Codex CLI
  plus Gemini through Pi), in parallel, each under its own backend env, and
  writes one findings file per leg plus a manifest (label, backend, model,
  status, exit, seconds, file). A leg that fails, returns nothing, or runs
  past `CONSORT_PANEL_TIMEOUT` (default 1800 s; the leg's whole process
  group is killed) fails the panel (exit 3) with that leg's file emptied —
  the other legs' results stay on disk, but the configured panel did not
  run and the caller is told so; an all-excluded diff propagates as exit 4;
  stale leg files from a previous run are removed first. Every leg's stderr
  is relayed with a `[label]` prefix, so the backends' evidence lines stay
  visible. A provider-pinned Pi leg with no model unsets an ambient
  `CONSORT_PI_MODEL` so the provider default applies. Bash-native wall-clock
  cap (no `timeout` binary needed); `scripts/consort-panel.test.sh` pins the
  grammar, env plumbing, hard-fail, exit-4, timeout and stale-file rules
  against a stub reviewer.
- **`merge-findings.mjs` merges any number of findings sets.** Arguments
  are `<principal.json> <reviewer.json>...` (labels from basenames or
  `label=path`); findings cluster across all sets by file and line
  proximity, one finding per set per cluster, the representative being the
  most severe member. Sections: caught by more than one reviewer (tagged
  with every reviewer that caught it, sorted by agreement then severity),
  each reviewer's "only" section, then the principal's. A file that is
  missing, empty, `{}` or `{"findings":null}` is reported as **NO RESULT**
  in the report and exits 3 — previously it merged silently as an empty
  (clean) set. `scripts/merge-findings.test.mjs` pins the contract.
- **Pi backend honours consort-scoped Google settings** for google
  providers, exported to the Pi process only and winning over the ambient
  Google variables when set: `CONSORT_GCP_PROJECT` → `GOOGLE_CLOUD_PROJECT`,
  `CONSORT_GEMINI_LOCATION` → `GOOGLE_CLOUD_LOCATION`,
  `CONSORT_GCP_CREDENTIALS` → `GOOGLE_APPLICATION_CREDENTIALS`. The
  credentials path must be a readable file or the backend refuses to start,
  so a typo cannot fall through to whatever ADC the shell holds. Lets a
  static config keep a Gemini leg alive where the user's ADC is an
  hourly-expiring workforce token.

### Changed
- `/consort:review`, the `review` skill and the lifecycle skill call
  `consort-panel.sh` and merge every leg; the presented order is now
  "caught by more than one reviewer", each reviewer's "only" section, then
  the principal's (was: both / Claude only / Codex only).
- Hardened by the gate before release (Codex, the blind security agent and
  the principal, on the panel's own diff): each panel run gets a fresh,
  exclusively created subdirectory of `CONSORT_PANEL_DIR` (concurrent
  panels sharing a parent no longer corrupt each other; a stale manifest
  can no longer read as the current verdict), the parent must be owned by
  the caller and not world-writable, every file is created with noclobber
  so a planted symlink is refused rather than followed, leg start times
  stay in memory (a stamp read back from disk was substituted into bash
  arithmetic, which expands array subscripts — command execution for anyone
  who could write the file), exit codes read from disk are validated as
  integers, the manifest is built by a real JSON serializer, reaped pids are
  cleared so a recycled pid is never signalled, cleanup is armed before the
  first leg starts and escalates TERM→KILL, a base ref starting with `-` is
  rejected (both in the panel and in `consort-review.sh`), `/consort:review`
  quotes its argument, `merge-findings.mjs` strips control characters from
  reviewer text, renders a severity outside the schema enum as `unknown`,
  and opens the report with a data-fence line. Pi backend:
  `CONSORT_GCP_CREDENTIALS` is resolved to an absolute regular file before
  the run changes directory, refused for workspace-write runs (an unfenced
  shell must not have a long-lived key in its environment), a run whose
  final message stopped at the output token limit is discarded as truncated,
  the JSON extractor says why it found no result, and `CONSORT_PI_RAW`
  captures the raw event stream as evidence. Second gate round (Codex + Gemini
  via Pi on the hardened diff): group-writable parents refused and run
  directories created 0700, legs resolving to the same backend+model refused
  (one reviewer twice is not agreement), empty spec fields rejected, HUP and
  EXIT covered by the cleanup with KILL sent only to a group that still
  exists, expired legs stopped together, a leg whose leader dies from outside
  has its group swept, the merge no longer chains clusters past the
  proximity, a Google key file inside the workdir is refused (the fence would
  let the reviewer read it), the workspace-write refusal covers the ambient
  `GOOGLE_APPLICATION_CREDENTIALS` too, and `CONSORT_PI_STDERR`/`CONSORT_PI_RAW`
  must be owned regular files (made owner-only; symlinks refused). Deferred, pre-existing: a
  repo-local `.claude/rules/` is auto-injected into every reviewer's prompt
  (0.4.0 design), which a hostile repo could use to talk every leg into an
  empty result at once — opt-in or fencing is tracked as follow-up.

## [0.8.0] — 2026-09-07

### Added
- **Pi backend — any vendor through one CLI, chosen with
  `CONSORT_BACKEND=pi`.** Reaches the Pi coding agent
  (`@earendil-works/pi-coding-agent`): Anthropic, OpenAI (API key or the
  ChatGPT/Codex subscription OAuth), Google Vertex (ADC / service-account
  key) and ~25 more providers behind one headless `--mode json` protocol.
  `CONSORT_PI_PROVIDER` picks the vendor (default `openai-codex`),
  `CONSORT_PI_MODEL` the model, `CONSORT_PI_THINKING` the effort. Every
  assistant message Pi emits names its provider, model and usage, so the
  served-model attestation is native: a run served by anything but the
  requested provider/model pair, or one Pi marked failed, is discarded as a
  failed call; every call prints one stderr evidence line (turns, tool
  calls, tokens, cached, reasoning, cost); the server-reported
  `responseModel` is checked too where an adapter surfaces it. Read-only
  calls are non-inheriting (`--tools read,grep,find,ls`, no user
  extensions/skills/templates, `--no-context-files`, `--no-approve`): Pi
  folds the workdir's and every ancestor's `AGENTS.md`/`CLAUDE.md` into the
  system prompt, so a hostile checkout's context file must not reach the
  reviewer. A fence extension (`scripts/pi-fence.mjs`, loaded with `-e` on
  every run) bounds Pi's tools to the workdir: every path argument of
  read/grep/find/ls/edit/write must resolve, symlinks followed, inside it,
  and read-only refuses bash/edit/write outright — Pi's own tools resolve
  absolute, `../` and `~` paths and there is no OS sandbox.
  Workspace-write gets the full tool set and the repo's context files, with
  `--no-approve` (`.pi/settings.json` `shellPath`, `.pi/extensions`). Every
  run is `--offline`; the backend refuses to start unless `rg` and `fd` are
  resolvable, because Pi's grep/find otherwise download an unpinned binary
  from GitHub on first use. Pi has no OS sandbox — the tool allowlist and
  the workdir are the fences — so workspace-write is opt-in
  (`CONSORT_PI_UNSANDBOXED_WRITE_OK=1`); `anthropic` as provider is refused
  unless `CONSORT_PI_SAME_VENDOR_OK=1` states the principal is not Claude;
  Pi >= 0.84.0 is required; extracted results are validated against the
  schema (type, required, enum, items — `{}` and `{"findings":null}` are
  not clean verdicts); providers without a built-in default model need
  `CONSORT_PI_MODEL`. The fence also judges the spelling variants Pi's
  `read` falls back to (NFD, curly apostrophe, AM/PM no-break space) so a
  repo cannot hide a symlink under a variant name; `scripts/pi-fence.test.mjs`
  pins 35 cases.

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
