---
description: Model-free security scan (Trivy + SonarQube when present), triaged for reachability, merged with a security-focused cross-model pass.
---

# /consort:scan

Run the deterministic scanner tier on the working tree, then triage. Scanners
and model reviewers find disjoint defect populations; this command produces
the scanner column and your reachability verdicts on it.

Arguments (optional workdir, default = current repo root):

```text
$ARGUMENTS
```

## Steps

1. Read `rules/security-review.md` under `$CLAUDE_PLUGIN_ROOT` — it governs
   this whole pass.
2. Run `bash "$CLAUDE_PLUGIN_ROOT"/scripts/consort-scan.sh $ARGUMENTS` and
   capture stdout to a temp file. Read stderr: every SKIPPED line goes into
   your report verbatim — a scan that ran nothing must say so.
3. Triage each finding per the pack's reachability rules: reachable / fixture
   or dead code / pre-existing debt outside the current change. Never echo
   matched secret material while triaging.
4. For a security-focused second opinion on the scanned tree's diff, run the
   review duet from INSIDE that tree (cd to the workdir first when one was
   given — `/consort:review`'s argument is a base ref, not a workdir; running
   it from elsewhere reviews the wrong repository). The security pack is
   always injected into both reviewers.
5. Report: findings that gate (reachable criticals, live secrets, vulnerable
   deps just added), then pre-existing debt, then what was skipped and why.
