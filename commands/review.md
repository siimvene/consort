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

1. Read the full skill instructions at `skills/review/SKILL.md` under `$CLAUDE_PLUGIN_ROOT` and follow the "Review loop" section exactly.
2. Produce your own findings on the diff in the `schemas/findings.schema.json` shape and write them to a temp file.
3. Run `bash "$CLAUDE_PLUGIN_ROOT"/scripts/consort-review.sh $ARGUMENTS` to get Codex's structured findings.
4. Run `node "$CLAUDE_PLUGIN_ROOT"/scripts/merge-findings.mjs <your-findings.json> <codex-findings.json>`.
5. Present the merged result, leading with "Both agree" (high confidence) and "Codex only" (what you missed).
