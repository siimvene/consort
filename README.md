# consort

Cross-model second opinion for Claude Code, backed by a local Codex CLI.

Claude orchestrates, plans, and reviews. Codex (gpt-5.6) implements and cross-reviews.
The harness surfaces the findings **only one model caught**, which is where most of the
value is: the SWE-chat 4-tool study found 93.4% of issues were caught by exactly one
tool, so a panel of one model reviewing itself misses the majority.

## Why two model families

A model reviewing its own family shares its blind spots ("borrowed confidence"). Codex
is a different vendor and training run, so its disagreement carries information. This
also splits cost sensibly: Codex runs on flat-rate ChatGPT-subscription quota as the
implementer, Claude stays on the orchestration and review it is best at.

## Requirements

- Claude Code with plugin support
- `codex` CLI on PATH, authenticated, able to reach a `gpt-5.6` model
  (check: `codex exec -m gpt-5.6-sol "reply OK"`)
- `node` and `git`

## Install

```
/plugin marketplace add <path-or-git-url-of-this-repo>
/plugin install consort@consort
```

Requires the `claude` and `codex` CLIs on PATH (the implementer model defaults to
`gpt-5.6-sol`; override with `CONSORT_IMPL_MODEL`).

## Use

```
/consort:plan  <task>     # cross-model plan review before writing code
/consort:review [base]    # cross-model review of the working diff
```

Or drive the bridge directly:

```
bash scripts/consort-review.sh            # Codex's structured findings on uncommitted changes
node scripts/merge-findings.mjs a.json b.json
```

## Layout

```
.claude-plugin/plugin.json      manifest
.claude-plugin/marketplace.json local marketplace wrapper
commands/review.md              /consort:review
commands/plan.md                /consort:plan
skills/review/SKILL.md            orchestration logic (role topology, loops)
scripts/consort-review.sh         Codex bridge: diff -> structured findings
scripts/merge-findings.mjs      surface unique-per-model findings
schemas/findings.schema.json    shared findings shape (both models emit this)
```

## Status

v0.1.0 draft skeleton. See `AGENTS.md` for the design rationale and the roadmap
(structural CI gates, routing scoreboard).
