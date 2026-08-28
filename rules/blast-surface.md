# Blast-surface sweep (built-in review methodology)

A diff-scoped review finds defects inside the diff. Most escaped regressions live
outside it: in consumers of what the diff changed. Before findings are complete,
run this sweep. It is mechanical on purpose; do not skip steps because the change
looks small.

1. **Changed-lifecycle inventory.** List every artifact whose creation, deletion,
   ownership, ordering, or timing the diff changes: files, state records,
   processes, sockets/pipes, env vars, timers, locks, queue entries.

2. **Consumer sweep.** For each inventory item, search the whole repo for every
   reader and writer (symbol references, file paths, env var names, CLI flags).
   Re-derive each consumer's assumption under the new behavior and check it still
   holds. A consumer in a file the diff never touched is the classic escape.

3. **Removed-behavior side effects.** For every behavior the diff removes,
   replaces, or reorders, ask: what else did that behavior accomplish implicitly?
   Killing a process also killed its children and in-flight work; deleting a file
   also masked stale state; a synchronous step also bounded a race window. Name
   what now provides each side effect, or report the gap as a finding.

4. **Runtime contracts.** Check configured constraints that bound the changed
   code still hold: timeouts in hook/CI/harness configs, schema contracts,
   retry/rate limits, and documented behavior in README, docs, and command help.
   Documentation that now lies about behavior is a finding.

5. **Test suite** (principal reviewer only; a read-only cross-reviewer states
   that it could not run tests and defers to the principal's result). Run the
   project's own test suite. Compare failures against a pre-change baseline on
   the same machine (some suites have environmental failures); any new failure
   is a finding. Running tests executes the diff's code: do this only for
   trusted diffs (your own work, or a contributor branch you have read); for an
   untrusted diff, run in a sandbox or skip with an explicit note in the review
   output. "The change is miniature" is not an exemption; miniature lifecycle
   changes are where this pack earns its keep.

6. **Peer-concurrency sweep.** For every shared artifact in the step-1 inventory
   (workspace-scoped files, records, sockets, locks), assume TWO instances of the
   consumer run at once: two sessions, two CI jobs, a reaper plus an owner. Walk
   the create / reuse / teardown interleavings. Classic escapes: one peer tears
   down state another peer still uses; a "session cleanup" deletes a
   workspace-wide pointer; two creators race a singleton into a duplicate.

7. **Destructive-action gate.** For every kill, delete, overwrite, or interrupt
   the diff adds or keeps, check four things. Identity: prove the handle still
   denotes the entity you meant, because PIDs get reused, paths get re-created,
   records go stale; presence of a file or record is not liveness, so probe
   readiness where it matters. Scope: destroy only what you can prove you
   created; an ownership marker beats a name pattern, and never recurse over a
   caller-selected path. Bound: every blocking wait on a shutdown or cleanup
   path carries a deadline and a forced fallback. Symmetry: cleanup resolves
   configuration the same way the happy path does; a cleanup that ignores the
   configured endpoint/path acts on the wrong instance.

8. **Fix-introduced invariants propagate.** When a revision adds a guard
   (ownership check, bound, validation) at one site, enumerate every other site
   with the same shape and check it there. A guard added at one of N sites is
   N-1 findings, not a fix. This step exists because review-fix regressions
   cluster exactly here.

When a finding comes from this pack, name the step in the finding title
(for example: "blast-surface step 3: SessionEnd no longer kills in-flight turns").
