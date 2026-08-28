# Finding discipline and the fix pass (built-in review methodology)

How findings are stated, graded, answered, and re-checked. Applies to every
consort round, both reviewers. Adapted from the review behaviors that made the
upstream codex-plugin-cc bot effective across multi-round PRs.

## 1. Every finding names its trigger

A finding states the concrete failure scenario: which inputs, state, or
interleaving produce which wrong outcome ("when session B shares A's working
directory and A ends first, B's in-flight request is killed"). A finding that
cannot name its trigger is a style comment; grade it MINOR or drop it. When a
later revision changes the picture, re-derive the scenario against the new code
before repeating the claim; "fresh evidence shows" beats "as previously noted".

## 2. Severity means something

- **CRITICAL / P1**: gates the merge. Fixed before anything else happens.
- **SERIOUS**: fixed before the next feature; a maintainer may gate on it.
- **MINOR / P2**: acknowledging in a PR comment with a rationale is a
  legitimate disposition. Code churn purely to silence a reviewer is not a fix;
  it is where new defects enter under review pressure.

When emitting machine-readable findings (`schemas/findings.schema.json`, whose
severity enum is `critical/high/medium/low`), map: CRITICAL → `critical`,
SERIOUS → `high`, MINOR → `medium` (or `low`). Never emit the prose labels as
schema values — backends reject or misrank them.

Grade honestly and let the grade carry the consequence. A reviewer who inflates
MINOR to SERIOUS to force action spends credibility the next real SERIOUS needs.

## 3. Convergence, not endurance

Track severity across rounds. When a round produces only findings weaker than
the previous round's, the review is converging: keep fixing CRITICAL/SERIOUS,
and answer the rest with reasoned acknowledgments unless a maintainer says one
gates the merge. Never predict a reviewer will go silent, and never keep
churning code to make it so.

## 4. The fix pass

After applying a round's findings, fixes that add guards (ownership checks,
bounds, validations) or touch teardown, destructive, or concurrency paths get
ONE scoped re-pass before the work is called done: blast-surface steps 7 and 8
over the fix diff alone. Did the new guard reach every same-shaped site? Are
the new waits bounded, the new deletions ownership-scoped, the cleanup config
resolution symmetric? Review-fix regressions cluster exactly here (observed
upstream: 3 of 9 rounds were holes the fixes introduced). One scoped pass, not
a loop; a full fresh review is a maintainer's call, never the default.
