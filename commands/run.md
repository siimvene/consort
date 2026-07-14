---
description: Drive the full consort lifecycle (interview → spec → plan → implement → review → gate) on a repo with a REQUEST.md, delegating implementation to sol and cross-reviewing with consort.
---

# /consort:run

Run the whole multi-vendor development lifecycle end to end as the orchestrating principal.

Workdir (a git repo containing `REQUEST.md`); leave blank to bootstrap a throwaway demo:

```text
$ARGUMENTS
```

## Steps

1. If no workdir is given, bootstrap one: `bash "$CLAUDE_PLUGIN_ROOT"/scripts/consort-demo.sh /tmp/consort-demo` and use it.
2. Read `skills/consort/SKILL.md` under `$CLAUDE_PLUGIN_ROOT` and follow every phase in order.
3. Stop at the human gates (scope, spec) unless told to run unattended; otherwise record assumptions and continue.
4. End by reporting each phase's artifact (one line each) and the final `consort-gate.sh` result.
