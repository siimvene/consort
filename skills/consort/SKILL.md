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
Read `REQUEST.md`. List what's unambiguous and what's genuinely unclear. Get sol's
divergent questions (the ones you didn't ask):
`consort-consult.sh schemas/spec.schema.json "<REQUEST + 'list the questions and edge cases this request leaves open'>"`.
Fold in any real gaps. **Gate: if ambiguity is high, ask the human; else record assumptions and continue.**

### 2. Spec (panel) → `.consort/spec.md`
Draft your own spec (schemas/spec.schema.json shape). In parallel get sol's independent
draft: `consort-consult.sh schemas/spec.schema.json "<REQUEST + 'write a spec'>"`. You
now hold ≥2 blind drafts. **Score** each on coverage, assumptions surfaced, failure modes,
testability. **Synthesize** one spec from the best, grafting the unique good ideas from the
others, and record which idea came from which voice. **Gate: human approves the spec.**

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
