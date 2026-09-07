---
name: review
description: Cross-model orchestration between Claude Code and a local Codex CLI. Claude orchestrates, plans, and reviews; Codex implements and provides an independent second opinion. Use when you want two different model families to cross-check work rather than one model reviewing itself.
version: 0.5.0
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

1. Read the built-in packs in `"$CLAUDE_PLUGIN_ROOT"/rules/`; then, if
   `CONSORT_RULE_PACKS` is set, every pack it names — otherwise a repo-local
   `.claude/rules/` directory if present (the script resolves packs the same
   way, so both reviewers read the same set).
2. Run the blast-surface sweep (`rules/blast-surface.md`) on the target diff:
   inventory what changed lifecycle, grep its consumers, hunt removed implicit
   behavior, check runtime contracts. Findings from the sweep are findings like
   any other. Do not skip it for small diffs.
3. Run the scanner tier: `bash "$CLAUDE_PLUGIN_ROOT"/scripts/consort-scan.sh`
   (Trivy, plus SonarQube when a server is configured — see
   `rules/security-review.md`). Capture its stdout findings and repeat every
   SKIPPED line from stderr in the review output; triage each scanner finding
   for reachability per the pack. Only the principal runs this — a read-only
   cross-reviewer states it could not scan and defers.
4. Run the project's own test suite and compare against a pre-change baseline
   on the same machine; any new failure is a finding. If the suite cannot run,
   say so explicitly in the review output instead of silently omitting it.
5. Produce your own findings on the target diff, in `schemas/findings.schema.json`
   shape (`file, line, severity, title, detail`), applying the packs.
   Write to a temp JSON file.
6. In parallel, get the independent passes:
   - **Cross-vendor reviewer(s):** `bash "$CLAUDE_PLUGIN_ROOT"/scripts/consort-panel.sh [base]`
     runs `consort-review.sh` once per leg of `CONSORT_REVIEWERS` (default
     `codex`; e.g. `codex,pi:google-vertex` for Codex plus Gemini through
     Pi), in parallel, and prints a manifest naming each leg's findings
     file and status. Packs are injected into every leg's prompt by the
     script. A leg with status `failed` or `timeout` (panel exit 3) means
     that reviewer DID NOT RUN: report it as a failed gate, never fold the
     remaining legs into a "clean" verdict. Check each leg's `seconds` and
     its relayed `[label]` stderr evidence line (tool calls, tokens, served
     model) — a multi-hundred-line diff reviewed in seconds did not happen.
   - **Security side-agent:** write the exact diff under review to a temp
     file (same diff for uncommitted, staged, or branch-vs-base targets),
     then spawn the plugin's `security-reviewer` agent (non-inheriting —
     never a context-forking spawn) with the workdir, that diff file path,
     and the rule pack paths. The agent has no shell by design and never
     regenerates the diff itself. It reviews security classes only and
     returns the same findings schema. Same vendor as you, different
     context: it covers the independence axis the duet's cross-vendor pass
     doesn't need, and it reads the diff without your authoring assumptions.
7. Merge: `node "$CLAUDE_PLUGIN_ROOT"/scripts/merge-findings.mjs claude.json <dir>/codex.json [<dir>/pi-google-vertex.json ...]`
   — every leg file the manifest lists. Exit 3 from the merge means a file
   was empty or not a findings array (NO RESULT in the report): a failed leg,
   not a clean one.
8. Present in this order: **Caught by more than one reviewer** (act first),
   each reviewer's **only** section (what you missed, the real payoff),
   **Claude only** (no cross-vendor reviewer caught), then **Security agent**
   (side-agent findings; fold one into a duet finding only when it names the
   SAME trigger — two defects can share a file and line, so location match
   alone never discards a finding), then
   **Scanners** (the deterministic tier from step 3, with your reachability
   verdicts). Verify each cross-model or side-agent finding
   before treating it as real; a second model's finding is a lead, not a verdict.
9. Grade, answer, and (when fixes touch guards, teardown, or concurrency paths)
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
