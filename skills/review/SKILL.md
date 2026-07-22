---
name: review
description: Cross-model orchestration between Claude Code and a local Codex CLI. Claude orchestrates, plans, and reviews; Codex implements and provides an independent second opinion. Use when you want two different model families to cross-check work rather than one model reviewing itself.
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

If `CONSORT_RULE_PACKS` is set (colon-separated files or directories of `.md`/`.mdc`
rule packs), BOTH reviewers use it: `consort-review.sh` injects the packs into
Codex's prompt automatically, and you must read the same files and apply them to
your own findings pass. One written standard, two independent readings. Pack
content lives in the org's standards repo — never inside this plugin.

## Review loop (`/consort:review`)

1. If `CONSORT_RULE_PACKS` is set, read every pack it names first.
2. Produce your own findings on the target diff, in `schemas/findings.schema.json`
   shape (`file, line, severity, title, detail`), applying the packs where set.
   Write to a temp JSON file.
3. Get Codex's findings: `consort-review.sh` returns the same schema (packs are
   injected into its prompt by the script).
4. Merge: `node "$CLAUDE_PLUGIN_ROOT"/scripts/merge-findings.mjs claude.json codex.json`.
5. Present in this order: **Both agree** (act first), **Codex only** (what you missed,
   the real payoff), **Claude only** (Codex missed). Verify each cross-model finding
   before treating it as real; a second model's finding is a lead, not a verdict.

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
