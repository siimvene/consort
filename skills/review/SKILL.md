---
name: review
description: Cross-model orchestration between Claude Code and a local Codex CLI. Claude orchestrates, plans, and reviews; Codex implements and provides an independent second opinion. Use when you want two different model families to cross-check work rather than one model reviewing itself.
version: 0.6.0
---

# review — cross-model review (Claude + Codex)

The point of this skill is heterogeneity. A model reviewing its own family shares its
blind spots. Pairing Claude with Codex (a different vendor and training run) is what
makes the second opinion worth anything.

## Role topology (cost-tiered)

- **Claude = orchestrator + reviewer.** Plans, reads diffs, reviews, runs tests, makes
  the judgment calls. Rarely writes bulk code.
- **Codex (gpt-5.6) = implementer + cross-reviewer.** Does the typing on flat-rate
  ChatGPT-subscription quota, and reviews Claude's output.

Whichever model authors, the other verifies. When they disagree, surface both rather
than silently picking one.

## Bridge

Codex runs non-interactively via the local CLI. Key invocations:

```bash
# structured review of a diff (read-only sandbox, JSON out per findings.schema.json)
bash "$CLAUDE_PLUGIN_ROOT"/scripts/consort-review.sh [base-ref]

# generic read-only consult
codex exec -m gpt-5.6-sol -s read-only "<prompt>"

# Codex's native, richer review (human-readable, not structured)
codex exec review --uncommitted
```

`CONSORT_IMPL_MODEL` overrides the model. Verify the account can reach it first:
`codex exec -m gpt-5.6-sol "reply OK"`.

## Rule packs (shared rubric)

Pack resolution, in order: built-in methodology packs from this plugin's
`rules/` directory (always active); then `CONSORT_RULE_PACKS` (colon-separated
files or directories of `.md`/`.mdc` rule packs) if set; otherwise a repo-local
`.claude/rules/` directory if present. BOTH reviewers use the same packs:
`consort-review.sh` injects them into Codex's prompt automatically, and you
must read the same files and apply them to your own findings pass. One written
standard, two independent readings.

Org coding standards (what code must look like) live in the org's standards
repo, never inside this plugin. The plugin's own `rules/` directory holds only
vendor-neutral review methodology (how to review): `rules/blast-surface.md`,
the consumer-sweep discipline that catches regressions living outside the
diff; `rules/finding-discipline.md`, which governs how findings are
stated, graded, answered across rounds, and re-checked after fixes; and
`rules/security-review.md`, which pairs the deterministic scanner tier
(`consort-scan.sh`) with the model-tier security checks scanners cannot do.

## Review loop (`/consort:review`)

The principal's own reading of the diff does NOT happen in this session. It
runs in the plugin's `code-reviewer` agent — non-inheriting, no shell, the
same shape as the security side-agent — for two reasons. Independence: a
reviewer who watched the change being made reads intent, not code. Cost: a
review pass is 30 to 40 tool calls, and every one of them re-reads the whole
session it runs in; at the context sizes an authoring session reaches, that
pass alone was most of a review's bill (measured: the security side-agent
does its whole pass in ~110k tokens over 19 to 32 calls). Your job here is
to gather the mechanical evidence, spawn the readers, merge, verify, present.

1. Resolve the pack paths: the built-in packs in `"$CLAUDE_PLUGIN_ROOT"/rules/`;
   then, if `CONSORT_RULE_PACKS` is set, every pack it names — otherwise a
   repo-local `.claude/rules/` directory if present (`consort-review.sh`
   resolves packs the same way, so every reader gets the same set). Pass the
   paths on; do not read the packs into this session.
2. Write the exact diff under review to a temp file — the same diff for
   uncommitted, staged, or branch-vs-base targets, with the same
   `CONSORT_DIFF_EXCLUDE` the panel applies. Both agents read this file and
   never regenerate it.
3. Run the scanner tier: `bash "$CLAUDE_PLUGIN_ROOT"/scripts/consort-scan.sh > <dir>/scan.json`
   (Trivy, plus SonarQube when a server is configured — see
   `rules/security-review.md`). Repeat every SKIPPED line from stderr in the
   review output; triage each scanner finding for reachability per the pack.
   Only the principal runs this — a read-only cross-reviewer states it could
   not scan and defers.
4. Run the test suite through `bash "$CLAUDE_PLUGIN_ROOT"/scripts/consort-test.sh [base]`
   (blast-surface step 5). It runs the suite for head and for a worktree of
   the base ref, keeps both logs on disk, and prints one summary line plus
   the NEW failures and the run directory — that is all of it that belongs
   in this context; do not `cat` the logs. Exit 1 = new failures (findings);
   exit 2 = the suite did not run; exit 3 = head ran but the baseline could
   not — say so in the review output, never fold either into "tests green".
   Trusted diffs only: the suite executes the diff's code.
5. In parallel, get the independent passes:
   - **Principal reader:** spawn the plugin's `code-reviewer` agent
     (non-inheriting — never a context-forking spawn) with the workdir, the
     diff file path, the pack paths, and the `result.json` path from step 4.
     It runs the blast-surface sweep with repo access, turns each new test
     failure into a finding, and returns the findings schema. Save its JSON
     as `claude.json`: this is the "Claude only" column of the merge.
   - **Cross-vendor reviewer(s):** `bash "$CLAUDE_PLUGIN_ROOT"/scripts/consort-panel.sh [base]`
     runs `consort-review.sh` once per leg of `CONSORT_REVIEWERS` (default
     `codex`; e.g. `codex,pi:google-vertex` for Codex plus Gemini through
     Pi), in parallel, and prints a manifest naming each leg's findings
     file and status. Packs are injected into every leg's prompt by the
     script. A leg with status `failed` or `timeout` (panel exit 3) means
     that reviewer DID NOT RUN: report it as a failed gate, never fold the
     remaining legs into a "clean" verdict. Panel exit 4 means every changed
     file was excluded: nothing was reviewed, do not merge. Check each leg's `seconds` and
     its relayed `[label]` stderr evidence line (tool calls, tokens, served
     model) — a multi-hundred-line diff reviewed in seconds did not happen.
   - **Security side-agent:** spawn the plugin's `security-reviewer` agent
     (non-inheriting — never a context-forking spawn) with the workdir, the
     same diff file path, and the rule pack paths. The agent has no shell by
     design and never regenerates the diff itself. It reviews security
     classes only and returns the same findings schema. Same vendor as you,
     different context: it covers the independence axis the duet's
     cross-vendor pass doesn't need, and it reads the diff without your
     authoring assumptions.
   Each agent's return is a findings JSON of at most a few hundred lines;
   that, the panel manifest, and the scan and test summaries are the whole
   of what this step adds to your context.
6. Merge: `node "$CLAUDE_PLUGIN_ROOT"/scripts/merge-findings.mjs claude.json <dir>/codex.json [<dir>/pi-google-vertex.json ...]`
   — every leg file the manifest lists. Exit 3 from the merge means a file
   was empty or not a findings array (NO RESULT in the report): a failed leg,
   not a clean one.
7. Present in this order: **Caught by more than one reviewer** (act first),
   each reviewer's **only** section (what you missed, the real payoff),
   **Claude only** (no cross-vendor reviewer caught), then **Security agent**
   (side-agent findings; fold one into a duet finding only when it names the
   SAME trigger — two defects can share a file and line, so location match
   alone never discards a finding), then
   **Scanners** (the deterministic tier from step 3, with your reachability
   verdicts). Verify each cross-model or side-agent finding
   before treating it as real; a second model's finding is a lead, not a verdict.
   Verify by reading the named range, not the file: this session is the
   expensive one, and it is at its largest right here.
8. Grade, answer, and (when fixes touch guards, teardown, or concurrency paths)
   re-check per `rules/finding-discipline.md`: the fix pass is part of the
   review, not a new review.

## Plan loop (`/consort:plan`)

1. Draft a plan: steps plus the failure modes you already considered.
2. Have Codex refute it (read-only consult). Cross-vendor plan review catches design
   mistakes before they cost implementation time.
3. Reconcile valid objections; record disagreements with rationale.
4. Proceed to implementation only after the plan survives the refutation pass.

## What this skill deliberately does not do

- No auto-implementation from Codex without a review pass.
- No prompt-level "guardrails" standing in for real gates. Structural checks belong in
  CI (see AGENTS.md), not in a model's instructions, because a model can be talked out
  of its own prompt.
