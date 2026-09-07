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

1. Read the full skill instructions at `skills/review/SKILL.md` under `$CLAUDE_PLUGIN_ROOT` and follow the "Review loop" section exactly — including the scanner tier (`consort-scan.sh`), the test runner (`consort-test.sh`), and both blind agents, not just the duet.
2. Write the exact diff under review to a temp file. Run `bash "$CLAUDE_PLUGIN_ROOT"/scripts/consort-scan.sh` and `bash "$CLAUDE_PLUGIN_ROOT"/scripts/consort-test.sh "$ARGUMENTS"` (logs stay on disk; only their summary lines belong in this session — never `cat` a test log here).
3. In parallel: spawn the plugin's `code-reviewer` agent (non-inheriting; workdir, diff file, pack paths, the test `result.json`) for the principal's findings — you do NOT review the diff in this session; run `bash "$CLAUDE_PLUGIN_ROOT"/scripts/consort-panel.sh "$ARGUMENTS"` (the argument is a git ref, nothing else) for the cross-vendor reviewers' structured findings (one leg per entry of `CONSORT_REVIEWERS`, default `codex`; the manifest names each leg's file and status — a `failed`/`timeout` leg is a failed gate, not a clean one; panel exit 4 means every changed file was excluded, so stop and report that nothing was reviewed instead of merging); and spawn the `security-reviewer` side-agent per the skill (same diff file; the agent has no shell).
4. Run `node "$CLAUDE_PLUGIN_ROOT"/scripts/merge-findings.mjs <code-reviewer findings.json> <every leg file from the manifest>`.
5. Present all sections per the skill: "Caught by more than one reviewer", each reviewer's "only" section (what the principal reader missed), "Claude only", "Security agent", "Scanners", and the test summary line — a report that omits any of the last three is incomplete even if the panel ran.
