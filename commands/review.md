---
description: Cross-model review of the current diff — Claude and Codex review independently, then surface the findings only one caught.
---

# /consort:review

Run a two-model review of the working changes. You (Claude) and Codex (gpt-5.6)
review the same diff independently; then merge and surface the divergence, because
the findings that matter most are the ones a single model would have missed.

Arguments (optional base ref to diff against, default = uncommitted vs HEAD):

```text
$ARGUMENTS
```

## Steps

1. Read the full skill instructions at `skills/review/SKILL.md` under `$CLAUDE_PLUGIN_ROOT` and follow the "Review loop" section exactly — including the scanner tier (`consort-scan.sh`) and the blind `security-reviewer` side-agent, not just the duet.
2. Produce your own findings on the diff in the `schemas/findings.schema.json` shape and write them to a temp file.
3. In parallel: run `bash "$CLAUDE_PLUGIN_ROOT"/scripts/consort-panel.sh $ARGUMENTS` for the cross-vendor reviewers' structured findings (one leg per entry of `CONSORT_REVIEWERS`, default `codex`; the manifest names each leg's file and status — a `failed`/`timeout` leg is a failed gate, not a clean one), and spawn the security side-agent per the skill (diff written to a temp file; the agent has no shell).
4. Run `node "$CLAUDE_PLUGIN_ROOT"/scripts/merge-findings.mjs <your-findings.json> <every leg file from the manifest>`.
5. Present all sections per the skill: "Caught by more than one reviewer", each reviewer's "only" section (what you missed), "Claude only", "Security agent", "Scanners" — a report that omits the last two is incomplete even if the panel ran.
