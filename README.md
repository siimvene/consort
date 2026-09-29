<div align="center">

<img src="assets/wordmark.svg" alt="consort" width="340">

**A two-vendor development lifecycle for Claude Code.**<br>
The expensive model orchestrates and judges, the cheap model does the volume,<br>
and no model's work ships on its own word.

<img src="https://img.shields.io/badge/license-MIT-c07a3e" alt="MIT license">
<img src="https://img.shields.io/badge/Claude_Code-plugin-2e9a9a" alt="Claude Code plugin">

</div>

---

## The roster — two voices, by design

| | 🟠 principal | 🔷 implementer |
|---|---|---|
| **Reference pair** | Claude Code session (e.g. `claude-fable-5`) | `codex exec` (default `gpt-5.6-sol`) |
| **Job** | Orchestrates every phase, holds the thread, reviews, adjudicates, and **verifies everything itself**. Writes glue, never bulk code. Also a blind panel voice via headless `claude -p`. | Implements in a workspace-write sandbox, and serves as the second blind voice in panels and reviews. Returns schema-forced results, never prose. |
| **Swap it** | any strong session model | model via `CONSORT_IMPL_MODEL`; whole vendor via `CONSORT_BACKEND=codex\|gemini\|pi` (Pi: any provider via `CONSORT_PI_PROVIDER`); several at once for review via `CONSORT_REVIEWERS` |

Cross-vendor is the point: two model families don't share blind spots (in the SWE-chat
4-tool study, 93.4% of issues were caught by exactly one tool). Every substantive
artifact gets touched by both.

## The pipeline

```mermaid
flowchart LR
    A["1 · interview<br/><i>scope + assumptions</i>"] --> B["2 · spec<br/><i>blind panel + synthesis</i>"]
    B --> C["3 · plan<br/><i>tasks + DoD, refuted</i>"]
    C --> D["4 · implement<br/><i>delegate, then verify</i>"]
    D --> E["5 · review<br/><i>blind duet, merged</i>"]
    E --> F["6 · gate<br/><i>no model: tests, CI</i>"]

    classDef both fill:#5fb47e,stroke:#3a8556,color:#10241a
    classDef principal fill:#d6934f,stroke:#a85f2c,color:#241505
    classDef impl fill:#43b4b4,stroke:#1c757b,color:#082222
    classDef gate fill:#9aa4b0,stroke:#5b6470,color:#14181d
    class A,B,E both
    class C principal
    class D impl
    class F gate
```

Each phase writes its artifact before advancing; any phase resumes from disk.

| # | Phase | Who acts | What happens | Artifact |
|---|---|---|---|---|
| 1 | **interview** 🚧 | 🟠 + 🔷 | Scope the request; the implementer proposes the questions the principal didn't ask | `interview.md` |
| 2 | **spec** 🚧 | 🟢 both, blind | Both voices draft **blind**; the principal scores and synthesizes, grafting the best of each with attribution | `spec.md` + both drafts |
| 3 | **plan** | 🟠 refuted by 🔷 | Decompose into tasks, each with a mechanical definition of done; the implementer refutes the plan | `plan.md` · `tasks.json` |
| 4 | **implement** | 🔷 types, 🟠 verifies | Delegate via five-part briefs; the principal runs every task's done-check itself | `tasks/*.result.json` |
| 5 | **review** | 🟢 both, blind | Every reviewer reads the same diff blind (one implementer, or a panel of several vendors via `CONSORT_REVIEWERS`); findings merge into *caught-by-more-than-one / each-reviewer-only / principal-only* | `review.md` |
| 6 | **gate** | ⚙️ no model | Structural check that trusts nobody: tests, CI, sources untouched, claims traced | exit code |

🚧 = human gate (scope and spec). Everything between runs unattended.

## Dependencies

Consort does not work standalone. Before installing, you need:

1. **Codex CLI** — `codex` on PATH, authenticated. Sanity check:
   `codex exec -m gpt-5.6-sol "reply OK"` (override the model with
   `CONSORT_IMPL_MODEL`).
2. **Codex plugin for Claude Code** (recommended) — `codex@openai-codex` (from
   [openai/codex-plugin-cc](https://github.com/openai/codex-plugin-cc)). Consort's
   default backend is this plugin's companion runtime (see "Codex backends" below);
   without it consort falls back to raw `codex exec`, which loses session reuse.
3. **Claude Code**, plus `node` and `git` on PATH.

## Install & use

```
/plugin marketplace add https://github.com/siimvene/consort
/plugin install consort@consort
```

```
/consort:run [workdir]    # the whole lifecycle on a repo containing REQUEST.md
/consort:review [base]    # cross-model review of the working diff
/consort:plan <task>      # cross-vendor plan refutation before code is written
/consort:scan [workdir]   # model-free security scan (Trivy/Sonar), triaged
```

**Rule packs:** point `CONSORT_RULE_PACKS` at your org's rule packs (colon-separated
files or dirs of `.md`/`.mdc`) — or vendor packs into the repo at
`.claude/rules/`, which is picked up automatically when the variable is unset.
Both reviewers — Codex via the script, the principal via the skill — review
against the same written standard. Org coding standards live in your standards
repo; the plugin itself ships only vendor-neutral review methodology in its
`rules/` directory (`blast-surface.md`, `finding-discipline.md`, and
`security-review.md`, always injected since 0.4.0, no setup needed).

**Diff excludes (opt-in):** every diff byte is re-sent on every reviewer turn,
so a repo that commits generated artefacts (baseline JSON, bundles) can name
them in `CONSORT_DIFF_EXCLUDE` (colon-separated git pathspec globs, matched
from the repo root). Nothing is excluded by default — lockfiles stay in,
because the supply-chain rule in `security-review.md` needs the model to see
dependency changes. Excluded paths are listed on stderr and handed to the
reviewer as fenced data; a diff that is empty only because of excludes exits
4, not 0. Whoever sets the variable owes the principal the same excludes, or
the two sides stop reviewing the same diff.

**Security scanners (optional):** when [Trivy](https://trivy.dev) is on PATH,
`consort-scan.sh` adds a deterministic third voice to every review — dependency
CVEs, leaked secrets, IaC misconfigurations — emitted in the same findings
schema the models use. A [SonarQube](https://www.sonarsource.com) leg joins it
when a server is reachable (`SONAR_HOST_URL`, default `http://localhost:9000`),
`SONAR_TOKEN` is set, and the repo has a `sonar-project.properties`. Neither is
required; every skipped scanner is reported loudly, never silently. Rule-based
scanners and model reviewers catch nearly disjoint defect sets — that
zero-overlap is why both tiers run.

**Two blind agents on the Claude side:** the plugin ships `agents/code-reviewer`
and `agents/security-reviewer`, both spawned by the review loop in parallel
with the cross-vendor pass, both non-inheriting and shell-less. The
code-reviewer is the principal's own column — it runs the blast-surface sweep
with repo access and returns the findings the authoring session would
otherwise have produced in place. Since 0.10.0 the authoring session does not
review the diff itself: a review pass is 30 to 40 tool calls, each re-reading
the whole session it runs in, so at a 200k–400k authoring context that one
pass was most of a review's token bill (the side-agent does its pass in ~110k
tokens over 19 to 32 calls; the principal's pass was never instrumented
because it had no boundary to instrument). The security-reviewer covers
security classes only and reads the same diff file. Both return the shared
findings schema, merge as their own columns, and are verified like any
cross-model lead.

**Tests out of context:** `scripts/consort-test.sh [base]` runs the project's
suite for head and for a worktree of the base ref, keeps both logs on disk,
and prints one summary line plus the *new* failures. That summary is all the
review session sees; the code-reviewer agent turns each new failure into a
finding from the `result.json` it leaves behind. Exit 2 (did not run) and 3
(no baseline) are reported as such, never as green.

Bootstrap a throwaway playground: `bash scripts/consort-demo.sh /tmp/consort-demo`

## Mechanics — what actually executes

| Piece | Does |
|---|---|
| `scripts/consort-delegate.sh` | Hands the implementer one task as a five-part brief (goal, paths, constraints, definition of done, return format); result is schema-forced JSON, logged to `.consort/tasks/` |
| `scripts/consort-consult.sh` | Read-only implementer with a schema: panel drafts, plan refutations, divergent questions |
| `scripts/consort-review.sh` + `merge-findings.mjs` | The duet: both voices review the same diff blind; the merge surfaces what only one model caught |
| `scripts/consort-panel.sh` | The panel: `consort-review.sh` once per leg of `CONSORT_REVIEWERS` (e.g. `codex,pi:google-vertex`), in parallel, one findings file per leg; a leg that fails or times out fails the panel; `merge-findings.mjs` takes all the legs at once |
| `scripts/consort-scan.sh` + `scan-to-findings.mjs` | Model-free scanner tier: Trivy (vulns, secrets, misconfig) and SonarQube (when a server is configured), converted into the shared findings schema |
| `scripts/consort-test.sh` | Model-free test tier: the suite on head and on a worktree of the base ref, logs on disk, one summary line and the new failures on stdout, `result.json` for the code-reviewer agent |
| `agents/code-reviewer`, `agents/security-reviewer` | The Claude-side readers: non-inheriting, shell-less, fed a diff file and the pack paths, returning findings JSON — the principal's column and the security column |
| `scripts/consort-gate.sh` | Model-free verdict — code: tests green; documents: sources untouched, claims traced |
| `schemas/` | One shared shape per artifact type (`spec`, `findings`, `task-result`) is what makes two vendors comparable and machine-mergeable |
| `.consort/` | The state bus: every phase resumes from disk; the session dying loses nothing |

## Backends

The implementer/reviewer ("sol") runs on one of three backends, chosen at
will with `CONSORT_BACKEND` (default `codex`): `codex` and `gemini` are
non-Anthropic by construction, so either satisfies the cross-vendor axis when
the principal is Claude; `pi` reaches whichever provider `CONSORT_PI_PROVIDER`
names and refuses `anthropic` unless you state the principal is not Claude.
`scripts/consort-backend.sh` is the dispatcher the caller scripts source.

### Panel — more than one reviewer per diff (`CONSORT_REVIEWERS`)

`CONSORT_BACKEND` picks one backend for everything. A review gate that wants
two vendors' readings on every diff — not "whichever is reachable" — runs
`scripts/consort-panel.sh [base]` instead of `consort-review.sh` directly.
It reads `CONSORT_REVIEWERS` (comma-separated legs, default `codex`), runs
`consort-review.sh` once per leg in parallel, each under its own backend env,
and writes one findings file per leg into a fresh, exclusively created
subdirectory of `CONSORT_PANEL_DIR` (default: a temp dir; the manifest's `dir`
names the run's own directory, created 0700, so concurrent panels sharing a
parent never touch each other's files; the parent must be a directory you
own, not a symlink, not group- or world-writable). Leg grammar: `codex[:model]`, `gemini[:model]`,
`pi[:provider[:model]]` — so `codex,pi:google-vertex` is the Codex CLI plus
Gemini 3.1 Pro through Pi, and `codex,gemini,pi:openai-codex:gpt-5.6-sol`
is three legs. A leg that pins a provider but no model unsets any ambient
`CONSORT_PI_MODEL`, so the provider's own default applies. Two legs that
resolve to the same backend and model are refused: one reviewer run twice
would present its own findings as agreement.

The manifest on stdout (`{"dir","exit","legs":[{label,spec,backend,model,
status,exit,seconds,file}]}`) says what each leg did; every leg's stderr is
relayed with a `[label]` prefix, which is where the backends' evidence lines
(tool calls, tokens, served model) land. A leg that fails, returns nothing,
or runs past `CONSORT_PANEL_TIMEOUT` (default 1800 s; the whole process group
is killed) makes the panel exit 3 with that leg's file empty — the other legs'
results stay on disk, but the panel you configured did not run, and the
gate's rule is hard-fail, never degrade. An all-excluded diff propagates as
exit 4: nothing was model-reviewed, so do not merge those files as if they
were readings. Interrupting the panel, or losing its terminal (HUP), kills
every leg's process group (TERM, then KILL if the group still exists), so no
reviewer keeps billing behind a dead wrapper; a leg whose leader dies from
outside is failed and its group swept the same way.

`merge-findings.mjs` takes any number of files (`<yours.json> <leg.json>...`,
labels from the basenames or `label=path`) and clusters findings across all
of them by file and line proximity (a cluster's whole span stays within the
proximity, so three findings ten lines apart are not chained into one), and
across files when one finding's title names the other's file as a whole-segment
path suffix (`tasks/run.py` names `src/kvart/tasks/run.py`; `subtasks/run.py`
does not; a bare basename shared by two paths in the merge names nothing) —
two reviewers anchoring one defect on the failing script and on the deleted
unit file are one finding, tagged `cross-file`. A cluster prints its
most severe member first and every other member under it, so nothing a
reviewer wrote is ever folded away; a finding that links two clusters merges
them, so the result does not depend on argument order: **caught by more than one reviewer**
first (tagged `[claude+codex+pi-google-vertex]`), then each reviewer's
**only** section — the second-opinion payoff — then the principal's. A file
that is missing, empty or not a findings array is reported as **NO RESULT**
in the report and exits 3: a leg that did not run and a leg that found
nothing never look the same.

### `CONSORT_BACKEND=codex` (default) — OpenAI

Reaches Codex through one of two transports, resolved by `scripts/codex-backend.sh`:

- **plugin** — the official Codex Claude Code plugin's companion runtime
  (`codex-companion.mjs task`), auto-detected under
  `~/.claude/plugins/cache/*/codex/*`. Uses the plugin's shared runtime and
  session plumbing; consult/review run read-only, delegation runs
  workspace-write (`--write`). The output schema travels as a prompt contract
  and is extracted/validated locally (the runtime has no `--output-schema`).
- **exec** — the raw `codex exec` CLI (the original bridge), with native
  `--output-schema` enforcement.

Auto-resolution prefers the plugin when installed; force either with
`CONSORT_CODEX_BACKEND=plugin|exec`.

For read-only calls (review, consult) the exec transport runs
`codex exec --ignore-user-config` with reasoning effort pinned
(`CONSORT_CODEX_REASONING`, default `high`): the reviewer sees none of your
`~/.codex/config.toml` plugins, hooks, MCP servers or developer instructions,
which keeps its context non-inheriting and its bill proportional to the diff.
Measured 2026-09-07 on a 25-file diff: a stock config whose plugin hook
matched "parallel mode" in a rule pack fanned the review into three subagents
(10.7M input tokens, 15 min); the bypass ran the same review in 2.46M tokens
and 8 min with the same real findings. Workspace-write (delegation) keeps
your config, because that is where sandbox narrowing and approval policy
live. `CONSORT_CODEX_USER_CONFIG=1` keeps it for read-only calls too — needed
where `config.toml` carries something the reviewer cannot run without, such
as a `[windows]` sandbox selector. A Codex CLI without the flag falls back
to the stock config with a warning on stderr. The plugin transport uses the
plugin runtime's own config.

#### Several Codex accounts: `CONSORT_CODEX_HOMES`

The Codex CLI keeps one login per `CODEX_HOME`. List several and a call
walks them in order until one answers:

```sh
CONSORT_CODEX_HOMES='~/.codex:~/.codex-second'   # explicit homes
CONSORT_CODEX_HOMES='@termscape'                 # every account Termscape signed in
```

A call moves to the next account **only** on a usage or rate limit, read from
codex's own error events (`--json` `error` / `turn.failed`) and stderr, never
from the transcript, so reviewing code that mentions "usage limit" cannot
trip it. Any other failure stops the walk: a second account would fail the
same way, and the review reports `DID NOT RUN` as before. Every attempt
leaves one stderr line naming the home that ran (or hit its limit), so the
panel's `[codex]` evidence says which account reviewed the diff.

- `@default` is `${CODEX_HOME:-~/.codex}`. `@termscape` is Termscape's
  (nodeterm) system account followed by each managed Codex account, at the
  same `~/.nodeterm/cx/<hash>` home Termscape derives; pending accounts are
  skipped. `CONSORT_TERMSCAPE_DATA_DIR` points at a non-default Termscape
  data dir and `NODETERM_CX_ROOT` at a non-default home root. A Claude node on
  the canvas does not inherit a Codex account, so without this list the
  codex leg always runs on `~/.codex`.
- Homes without an `auth.json` are skipped with a warning; duplicates are
  tried once; a leading `~/` is expanded.
- A home list forces the **exec** transport: the plugin's broker is started
  once under the first caller's `CODEX_HOME` and serves every later call on
  that account, so it cannot switch. `CONSORT_CODEX_BACKEND=plugin` together
  with a home list is refused.
- Delegation (workspace-write) fails over only when the limited attempt left
  the work tree byte-identical (a git tree hash before and after, untracked
  files included). A half-applied edit is never handed to a second account;
  outside a git work tree delegation does not fail over at all.
- `consort_impl_probe` walks the same list and prints `CODEX_ALIVE` when some
  account answered.

Each run starts from the first home again, so a limited first account costs
one refused call (seconds) per review until its window resets. Put the
account with headroom first when you know which one it is.

### `CONSORT_BACKEND=gemini` — Google (Vertex AI)

Reaches Gemini via ADC (`gcloud`/WIF), no API key, so it works where org policy
disallows keys. Two transports (`CONSORT_GEMINI_TRANSPORT=cli|api`, auto):

- **cli** — the `gemini` CLI (`@google/gemini-cli`) run in the workdir. Reads
  the repo for rule-pack sweeps and, in workspace-write, edits files — full
  implementer parity with Codex. Preferred when installed.
- **api** — the stdlib Vertex `generateContent` companion (`gemini-companion.py`).
  Diff-only, read-only; the CI fallback when the CLI isn't installed.

Config: `CONSORT_GEMINI_MODEL` (default `gemini-3.1-pro-preview`),
`CONSORT_GEMINI_LOCATION` (`global`; `europe-west4` for EU residency),
`CONSORT_GCP_PROJECT`, `CONSORT_GEMINI_STDERR` (file to append the CLI's stderr
to; dropped by default). The cli transport backslash-escapes every `@` in the
prompt — the CLI's `@file` expander otherwise reads a diff's `@@` hunk headers
as file references — and instructs the model to read touched files and sweep
callers before answering; left to itself, headless Gemini answers from the diff
alone. The cli transport also pins the model: gemini-cli rewrites unknown ids
that end in `flash` to its own flash default (measured 2026-09-07:
`gemini-3.8-flash` ran as gemini-3.5-flash), so every call enables the CLI's
pass-through resolver via a throwaway system settings file and checks the
`--output-format json` envelope's `stats.models` against the requested model —
a swap is a failed call, not a verdict. The same envelope prints one stderr
line per call (tool calls, input/cached/thought/output tokens), which is the
"did the reviewer really run" check without opening the session log.

### `CONSORT_BACKEND=pi` — any vendor via the Pi coding agent

One CLI, every vendor. [Pi](https://github.com/badlogic/pi-mono)
(`@earendil-works/pi-coding-agent`) is a minimal multi-provider coding agent:
Anthropic (Pro/Max OAuth or key), OpenAI (API key or the ChatGPT/Codex
subscription OAuth), Google Vertex (ADC or a service-account key, no API key)
and ~25 more, all behind one headless JSON-lines protocol. `CONSORT_PI_PROVIDER`
picks the vendor (default `openai-codex`), `CONSORT_PI_MODEL` the model
(defaults per provider: `gpt-5.6-sol`, `gemini-3.1-pro-preview`,
`claude-opus-4-8`), `CONSORT_PI_THINKING` the effort (`high`). Whether a Pi run
is cross-vendor depends on the provider, not on Pi: with the principal on
Claude, `anthropic` never satisfies the gate.

Why it earns a backend of its own: every assistant message Pi emits carries
the provider, the model id and the usage that served it, so the served-model
attestation the gemini cli transport had to bolt on is native here. Every
call prints one stderr line (turns, tool calls, tokens, cached, reasoning,
cost); a run served by any provider/model other than the requested pair is
discarded as a failed call; where an adapter surfaces the server-reported
model (`responseModel`), that is checked too. Read-only calls run with
`--tools read,grep,find,ls`, no user extensions, skills, prompt templates or
context files (non-inheriting, like Codex's `--ignore-user-config`) and
`--no-approve`. Context files are off on purpose: Pi folds the workdir's
`AGENTS.md`/`CLAUDE.md` and every ancestor directory's into the *system*
prompt; house rules for the review go in `.claude/rules`, which
`consort-review.sh` fences as data. Pi's own tools resolve any path
(absolute, `../`, `~`) and Pi has no OS sandbox, so consort loads a fence
extension (`scripts/pi-fence.mjs`) on every run: every path argument of
read/grep/find/ls/edit/write must resolve, symlinks followed, inside the
workdir, and in read-only mode bash/edit/write are refused outright
(live-tested: `~/.zshrc`, a symlink to `$HOME` inside the workdir and
`ls ..` blocked; a workdir file read). Workspace-write gets the full built-in
tool set and the repo's context files, still with `--no-approve`
(`.pi/settings.json` can set `shellPath`, `.pi/extensions` run at startup);
its `bash` is a shell the fence cannot bound, so that mode is opt-in
(`CONSORT_PI_UNSANDBOXED_WRITE_OK=1`); review and consult need no opt-in. Every run is `--offline`, the backend requires Pi >= 0.84.0 and
refuses to start unless `rg` and `fd` are already resolvable — Pi's grep/find
tools otherwise fetch an unpinned "latest" binary from GitHub on first use.
Extracted results are validated against the schema; `{}` and
`{"findings":null}` are not clean verdicts. Providers without a built-in default model need
`CONSORT_PI_MODEL` set explicitly.

Auth is Pi's own (`pi auth check --provider <id>`); Vertex reads
`GOOGLE_APPLICATION_CREDENTIALS` / ADC plus `GOOGLE_CLOUD_PROJECT` and
`GOOGLE_CLOUD_LOCATION`. For google providers the consort-scoped names are
honoured too and win when set, exported to the Pi process only:
`CONSORT_GCP_PROJECT`, `CONSORT_GEMINI_LOCATION` (the gemini backend's
variables) and `CONSORT_GCP_CREDENTIALS` (a service-account key file, resolved to an
absolute path before the run changes directory; must be a readable regular
file or the backend refuses to start rather than fall through to whatever
ADC the shell holds). That is how a machine whose user ADC is an
hourly-expiring workforce token keeps a Gemini leg alive from static config.
The key file is accepted for read-only runs only, where the fence refuses
bash and any read outside the workdir — and never from inside the workdir,
where the fence would let the reviewer read it; a workspace-write run refuses
any key file (consort-scoped or ambient `GOOGLE_APPLICATION_CREDENTIALS`),
because an unfenced shell one repo-injected `cat` away from a long-lived key
is not a trust boundary. Capture files (`CONSORT_PI_STDERR`, `CONSORT_PI_RAW`)
must be regular files you own, never symlinks, and are made owner-only. A run whose final message stopped at the output
token limit is discarded as truncated, not parsed as a partial result.
`CONSORT_PI_STDERR` captures Pi's stderr and `CONSORT_PI_RAW` its raw
`--mode json` event stream (both owner-only) — the evidence to open when a
run was discarded.

Delegation entries in `.consort/log.jsonl` record which backend + model served
each task.

## The rules that keep it honest

1. **Whichever model authors, the other verifies.** A finding is a lead, not a verdict: it gets checked against reality before it's reported.
2. **The principal verifies everything itself.** "The implementer says done" is never the end; every definition of done names a mechanical check, and the principal runs it.
3. **State lives on disk, not in context.** Any phase is resumable from `.consort/`; provenance ships with the work.
4. **Disagreement is surfaced, not averaged.** Panel synthesis grafts with attribution; review divergence is shown, adjudicated, logged.

## Design docs

- [`SPEC.md`](SPEC.md) — goals, roster, phase pipeline, panel mechanism, delegation contract
- [`AGENTS.md`](AGENTS.md) — design rationale and roadmap

---

> The pattern that keeps proving itself: **the second vendor's blind pass always finds something the first one structurally can't see.** That column is why consort exists.
