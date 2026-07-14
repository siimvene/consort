# consort — multi-vendor SDLC harness · SPEC v0.1

**consort** — a small ensemble. The cross-model review phase is also addressable on its own as `/consort:review`.

## 1. Goal

A single Fable-orchestrated session that carries a feature from a one-line request to
reviewed, gated code — pulling multiple model vendors into the phases where divergence
pays (interview, spec, plan), delegating implementation to sol 5.6, and cross-reviewing
the result. Fable holds the thread end to end; the human approves at gates, not between
every step.

**Acceptance target (the test):** given a one-line feature request on a fresh scratch
repo, the system produces — with no hand-holding between phases — a synthesized spec, a
refuted plan, sol-implemented code, a consort review, and a green gate. Success is measured
on whether the *orchestration* held, independent of how good the toy feature is.

## 2. Non-goals

- Not a general agent framework. One opinionated pipeline, this model roster.
- No autonomous merge/deploy. The gate produces a reviewed branch; a human ships it.
- No new inference infra. Thin glue over the `claude` and `codex` CLIs already here.
- Not "never banned" marketing. It is orchestration over two local CLIs plus one more.

## 3. Model roster & roles

| Handle | Backing | Role |
|---|---|---|
| **Fable** | Claude Code on `claude-fable-5` | Principal: drives every phase, holds state, synthesizes, reviews. Cheap enough to run constantly; never writes bulk code. |
| **sol** | `codex exec -m gpt-5.6-sol` | Workhorse: implements tasks (flat-rate quota), and is the second panel/review voice. |

The panel is exactly these two. Two different model families drafting blind is the
cross-vendor divergence; synthesis is across the two drafts. More vendors is not a goal.
This table is the reference pair — both seats are swappable (any strong session model as
principal; `CONSORT_IMPL_MODEL` overrides the implementer).

## 4. Phase pipeline

Each phase has: inputs, actors, mode, an artifact it writes, and a gate to advance.

| # | Phase | Actors / mode | Artifact written | Advance gate |
|---|---|---|---|---|
| 1 | **Interview** | Fable drives Socratic Q; sol proposes the questions Fable didn't ask | `.consort/interview.md` | ambiguity below threshold; human confirms scope |
| 2 | **Spec** | Panel: Fable + sol each draft a spec independently → Fable scores + synthesizes | `.consort/spec.md` | human approves the synthesized spec |
| 3 | **Plan** | Fable decomposes into tasks; sol refutes the plan (`consort:plan`) | `.consort/plan.md`, `.consort/tasks.json` | plan survives refutation |
| 4 | **Implement** | Per task: Fable delegates to sol (`codex exec`); Fable never writes bulk code | code on a branch + `.consort/scoreboard.md` | task DoD (its tests) pass |
| 5 | **Review** | Fable + sol review the diff independently → merge (`consort:review`) | `.consort/review.md` | no unresolved critical/high finding |
| 6 | **Gate** | CI script, no model | exit code | structural checks pass |

Human approval points: end of Interview (scope), end of Spec (the contract), and the
final branch. Everything between runs unattended.

## 5. Panel + synthesis mechanism (phases 1–2)

The point of the panel is divergence, so independence is the rule:

1. Both voices draft **blind**: sol via `codex exec` (read-only, schema-forced), and
   Fable's own draft written before it sees sol's.
2. Fable scores both drafts against fixed criteria: coverage of the request, unstated
   assumptions surfaced, failure modes named, and testability.
3. Fable synthesizes a single artifact from the stronger draft, **grafting** the unique
   good ideas from the other (not averaging — a merge that keeps the best of each).
4. The synthesis records, in the artifact, which ideas came from which voice (audit
   trail + the seed of routing telemetry).

## 6. Delegation contract (Fable → sol), phase 4

Every task handed to sol carries the five-part brief (from the operator delegation rule):
goal in one sentence, paths, constraints (surface allowlist + read-only vs write),
definition of done (the mechanical check), and return format capped short. Verbose output
stays on disk; sol returns a summary + a pointer. sol iterates until its DoD is observed
or it hits a blocker only the human can resolve — it does not hand unfinished checks back
to Fable.

## 7. State & handoff

Two stores, different lifetimes:

- **`.consort/` in the repo** — per-run phase artifacts (interview, spec, plan, tasks,
  scoreboard, review). Plain text, git-tracked, the handoff bus between phases. Any phase
  can be resumed by reading these.
- **A durable knowledge store of your choice (global)** — cross-run knowledge: routing
  lessons, which vendor wins which task type, design decisions worth keeping.

`scoreboard.md` is read on boot and used to bias task routing (Reddit-thread pattern).

## 8. Acceptance test — the throwaway target

Fixture: a fresh git repo with a tiny, unambiguous feature (candidate: a `tally` CLI —
read a file, print line/word/char counts with flags; clear DoD via tests). The feature is
disposable; the harness is under test.

Instruments (one observable per phase — if it can't be inspected, it isn't done):

- Interview → `.consort/interview.md` exists, ambiguity gate logged.
- Spec → `.consort/spec.md` shows ≥2 vendor drafts scored + a synthesis with attribution.
- Plan → `.consort/tasks.json` non-empty; refutation notes present.
- Implement → branch has commits authored via sol; each task's tests green.
- Review → `.consort/review.md` shows both-agree / model-only buckets.
- Gate → CI exits 0.
- **End to end:** one human command starts it, two approval gates, a reviewed branch out.
  No manual step between phases.

## 9. Build order (test-first, thin vertical slice)

Do **not** build all six phases at once. Prove the spine on one phase, end to end, then
widen:

1. **Slice 0 — the bridge spine.** Fable delegates one trivial task to sol and gets a
   structured result back, with `.consort/` handoff files. (Extends the working consort
   scripts.) Proves the substrate.
2. **Slice 1 — implement + review.** Phases 4–5 on the fixture: sol implements a one-task
   plan, then the cross-model review runs. (the review scripts already exist; wire delegation in front.)
3. **Slice 2 — the panel.** Phases 1–2: parallel blind drafts + synthesis. The riskiest,
   costliest part; build it once the spine is proven.
4. **Slice 3 — gate + scoreboard + full run** on the fixture.

Each slice ends with the fixture exercised and the phase's instrument observed.

## 10. Open questions / risks

- **Fable context budget.** Can one Fable session hold interview→gate without compaction
  losing the thread? Mitigation: `.consort/` files are the source of truth, not context.
- **Panel cost/latency.** The two blind drafts per front phase are the expensive part;
  measure on the fixture before deciding the panel earns its keep vs plain author+refuter.
- **Inter-phase failure.** If a phase fails (sol errors, gate red), where does control go?
  Default: stop at the phase, leave `.consort/` intact, resume after fix. No silent retry.
- **Naming.** Settled: the system is **consort**; the standalone review phase is `/consort:review`.
