# consort — design rationale

This harness is the personal-scale prototype of a cost-tiered, multi-vendor agent
topology. The design is not novel to this repo; it converges with a folk practice
observed across teams. consort just packages it as a Claude Code plugin.

## The four load-bearing ideas

1. **Cost-tiered role topology.** The expensive model orchestrates and reviews; the
   cheap model implements. This is the inverse of "use the top model for everything."
   Here Claude is the principal (plans, reads diffs, reviews, runs tests) and Codex on
   flat-rate quota does the typing.

2. **Cross-model second opinion.** Heterogeneous review beats a same-model panel. The
   anchor is the SWE-chat 4-tool study: 93.4% of issues were caught by exactly one
   tool. `merge-findings.mjs` makes this operational by ranking the unique-per-model
   findings above the agreed ones.

3. **Structural gates over prompt guardrails.** A model can be talked out of its own
   instructions. Enforcement belongs in CI, not in a prompt. This draft ships **no**
   active hook on purpose; the gate is a roadmap item (below), meant to live in the
   host repo's CI, not in consort's model instructions.

4. **Plan-first, cross-vendor.** The cheapest place to catch a design mistake is before
   implementation. `/consort:plan` has each model try to refute the other's plan.

## Roadmap

- **CI gate template.** A drop-in check for the host repo: PR body must carry purpose +
  test output + proof of execution; fail when a change touches `tests/` without
  touching `src/` (or the reverse), which catches assertions rewritten to match broken
  behaviour.
- **Routing scoreboard.** A plain-text per-task performance ledger, read on boot, used
  to route work to whichever model has done better on that kind of task. This is the
  seed of telemetry-driven model routing.
- **Verify-before-trust on cross-model findings.** A model's finding is a lead, not a
  verdict; add an adversarial verification pass before a finding is reported as real.

## Non-goals

- No auto-implementation from Codex without a Claude review pass.
- No vendor lock; the bridge is a thin shell around the `codex` CLI and is replaceable.
- No "cannot be banned" marketing. It is a plugin around two local CLIs; that is all.
