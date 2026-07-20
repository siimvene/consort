---
name: consort
description: Drive a full multi-vendor development lifecycle — interview, spec, plan, implement, review, gate — as the orchestrating principal, delegating implementation to a cross-vendor implementer (Codex by default) and cross-reviewing with consort. Use to take a feature request from idea to a reviewed, gated branch in one orchestrated run.
---

# consort — run the whole lifecycle

You are the **principal** — the model running this session. You hold the thread across every phase, make the
judgment calls, and never write bulk implementation code yourself — that goes to sol.
All phase state lives in `<workdir>/.consort/` so the run is resumable from disk.

Scripts referenced below live under `$CLAUDE_PLUGIN_ROOT` (the consort plugin root).
Set `CONSORT_IMPL_MODEL` to override the implementer model (default `gpt-5.6-sol`).

## Inputs

- A **workdir**: a git repo containing `REQUEST.md` (the feature request). Bootstrap a
  throwaway one with `scripts/consort-demo.sh <dir>`.

## Run the phases in order. Write each artifact before advancing.

### 1. Interview → `.consort/interview.md`
Read `REQUEST.md`. As principal, list what's unambiguous and what's genuinely unclear
(this is groundwork, not a panel draft). Then get **each vendor's divergent questions**
independently and in parallel — the ones a fresh reader would ask that you didn't:
- **sol (OpenAI):** `consort-consult.sh schemas/spec.schema.json "<REQUEST + 'list the questions and edge cases this request leaves open'>"`.
- **A fresh Anthropic-vendor agent** (non-inheriting subagent, per phase 2) with the same brief.

Fold in the real gaps both surface. **Gate: if ambiguity is high, ask the human; else record assumptions and continue.**

### 2. Spec (panel) → `.consort/spec.md`
**Do not author a panel draft yourself.** As principal you investigate (groundwork),
score, and synthesize — but the drafts must come from independent agents so the panel
is genuinely blind. Get **two independent blind drafts in parallel**:
- **sol (OpenAI):** `consort-consult.sh schemas/spec.schema.json "<REQUEST + 'write a spec'>"`.
- **A fresh implementer-tier agent for your own vendor (Anthropic):** spawn it with the
  same brief in a **non-inheriting** context (Claude Code: the Task/Agent tool with a
  non-`fork` subagent_type — `fork` inherits your context and defeats independence).
  Have it write its draft to `.consort/spec-<vendor>.json` and return only a short pointer.

You now hold ≥2 blind drafts, neither anchored to your orchestration context. **Score**
each on coverage, assumptions surfaced, failure modes, testability. **Synthesize** one spec
from the best, grafting the unique good ideas from the others, and record which idea came
from which voice. **Gate: human approves the spec.**

> Why not draft it yourself: the principal already holds the REQUEST framing and all prior
> context, so a principal-authored draft is not blind to that framing — it converges with
> the synthesis instead of diverging from it. An independent spawned agent per vendor is the
> only way both voices are truly independent. (Falls back to a principal-inline draft only
> if the principal's runtime cannot spawn subagents.)

### 3. Plan → `.consort/plan.md`, `.consort/tasks.json`
Decompose the spec into a short ordered task list (each task: id, goal, definition of done).
Have sol refute the plan: `consort-consult.sh schemas/findings.schema.json "<plan + 'what breaks, what is missing, what assumption is wrong'>"`. Reconcile valid objections. **Gate: plan survives refutation.**

### 4. Implement (delegate to sol)
For each task, write a five-part brief to a temp file and run:
`consort-delegate.sh <task-id> <brief-file> <workdir>`. sol implements in a workspace-write
sandbox and returns a task-result. Read the result; if `blocked`, resolve or escalate. Do
not write the implementation yourself.

### 5. Review (consort) → `.consort/review.md`
Produce your own findings on the diff (schemas/findings.schema.json). Get sol's:
`consort-review.sh` (alias for consort-review.sh on the workdir). Merge:
`merge-findings.mjs <your.json> <sol.json>`. Resolve every critical/high before advancing.

### 6. Gate (no model) → exit code
`consort-gate.sh <workdir>`. Structural checks + tests. Must exit 0.

## Output

A branch with the implemented feature, all `.consort/` artifacts, and a green gate.
Report: what each phase produced (one line each) and the final gate result. Verbose
output stays in `.consort/`; your summary stays short.
