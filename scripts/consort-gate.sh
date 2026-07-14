#!/usr/bin/env bash
# consort gate — structural checks + tests on the fixture repo. exit 0 = pass.
# The gate is a model-free CI check: it does not trust any agent's word.
#
# Usage: consort-gate.sh [workdir]
set -uo pipefail
WORKDIR="${1:-$PWD}"
cd "$WORKDIR" || { echo "GATE FAIL: no workdir $WORKDIR"; exit 1; }

fail=0
note() { echo "  - $1"; }

echo "== consort gate =="

# Structural: a test harness must exist, and the change must not be test-only.
# Diff-based and extension-agnostic (an impl file may have no extension, e.g. `tally`).
if [ ! -f test.sh ]; then note "no test.sh (a change must ship its own check)"; fail=1; fi
# Prefer the uncommitted/staged change; once committed, fall back to the tip commit.
changed="$(git diff HEAD --name-only 2>/dev/null)"
[ -n "$changed" ] || changed="$(git show --name-only --format= HEAD 2>/dev/null)"
if [ -z "$changed" ]; then
  note "no change under gate"; fail=1
else
  impl="$(printf '%s\n' "$changed" | grep -vE '(^|/)test\.sh$|^\.consort/|^\.omx/|^REQUEST\.md$' || true)"
  [ -n "$impl" ] || { note "change is test-only, no implementation touched"; fail=1; }
fi

# Behavioural: run the tests.
if [ -f test.sh ]; then
  if bash test.sh; then note "tests: green"; else note "tests: RED"; fail=1; fi
fi

if [ "$fail" -eq 0 ]; then echo "GATE PASS"; else echo "GATE FAIL"; fi
exit "$fail"
