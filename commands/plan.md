---
description: Cross-model plan review before any code is written — draft a plan, have Codex refute it, reconcile.
---

# /consort:plan

Plan-first, cross-vendor. Before a line of code is touched, you draft the plan and
Codex (gpt-5.6) tries to poke holes in it. Cross-vendor plan review reliably finds
something crucial missing in both directions; that is the cheapest place to catch a
design mistake.

Task to plan:

```text
$ARGUMENTS
```

## Steps

1. Read `skills/review/SKILL.md` under `$CLAUDE_PLUGIN_ROOT` and follow the "Plan loop" section.
2. Draft a concise implementation plan (steps + the failure modes you considered).
3. Ask Codex to refute it: `bash "$CLAUDE_PLUGIN_ROOT"/scripts/consort-review.sh` is diff-only, so for a plan pass Codex the plan text via `codex exec -m gpt-5.6-sol -s read-only "Refute this plan. What breaks, what's missing, what assumption is wrong? <plan>"`.
4. Reconcile: fold Codex's valid objections into the plan, note where you disagree and why.
5. Present the reconciled plan. Only then move to implementation (Codex implements, you review via `/consort:review`).
