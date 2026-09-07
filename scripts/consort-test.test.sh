#!/usr/bin/env bash
# bash scripts/consort-test.test.sh — pins consort-test.sh against a throwaway
# git repo whose test.sh fails whichever test names a file lists: baseline vs
# head comparison (only NEW failures are reported), the no-baseline mode, the
# output budget (a 600-line log stays on disk, stdout stays small), the
# wall-clock cap, a red head that parses no failure lines, the exit contract,
# and the flag-shaped-ref refusal. The working tree is never touched.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST="$HERE/consort-test.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1${2:+ — $2}"; fails=$((fails+1)); }
check() { if eval "$2"; then ok "$1"; else fail "$1" "$3"; fi; }

# ---- fixture repo -------------------------------------------------------------
R="$T/repo"; mkdir -p "$R"; cd "$R" || exit 1
git init -q .; git config user.email t@t; git config user.name t
cat > test.sh <<'SH'
#!/usr/bin/env bash
# fails every test named in FAILING (one per line); prints 600 lines of noise first
for i in $(seq 1 600); do echo "noise line $i: setting up fixture $i"; done
rc=0
for t in alpha beta gamma delta; do
  if grep -qx "$t" FAILING 2>/dev/null; then echo "FAILED tests/test_$t.py::test_$t (0.0${RANDOM}s)"; rc=1
  else echo "PASSED tests/test_$t.py::test_$t"; fi
done
[ -f SLEEP ] && sleep 30
[ -f CRASH ] && { echo "Segmentation fault"; exit 139; }
exit $rc
SH
printf 'alpha\n' > FAILING          # baseline: alpha already red
git add -A; git commit -qm base
printf 'alpha\nbeta\n' > FAILING    # head: beta newly red

# ---- 1. new failure vs baseline -----------------------------------------------
out="$(CONSORT_TEST_DIR="$T/runs" bash "$TEST" 2>"$T/err1")"; rc=$?
check "exit 1 when head adds a failure" '[ "$rc" = 1 ]' "rc=$rc"
check "summary names head/base failing counts and new" 'grep -qE "head exit 1 \(2 failing\), base exit 1 \(1 failing\), new 1" <<<"$out"' "$out"
check "the new failure is listed, the old one is not" 'grep -q "test_beta" <<<"$out" && ! grep -q "test_alpha" <<<"$out"' "$out"
check "duration stripped from the failure line" '! grep -qE "test_beta.*[0-9]s" <<<"$out"' "$out"
check "stdout stays small (log on disk)" '[ "$(wc -l <<<"$out")" -le 6 ]' "$(wc -l <<<"$out") lines"
dir="$(sed -n 's/^log: //p' <<<"$out")"
check "head.log holds the full 600-line run" '[ -f "$dir/head.log" ] && [ "$(grep -c "noise line" "$dir/head.log")" = 600 ]'
check "base.log holds the baseline run" '[ -f "$dir/base.log" ] && grep -q "FAILED tests/test_alpha" "$dir/base.log"'
check "result.json lists the new failure" 'node -e "const r=require(process.argv[1]);process.exit(r.new_failures.length===1&&/test_beta/.test(r.new_failures[0])&&r.baseline.status===\"ok\"?0:1)" "$dir/result.json"'
check "worktree removed after the run" '[ ! -e "$dir/base" ] && [ -z "$(git worktree list | grep -v "$R ")" ]'
check "working tree untouched" '[ "$(cat FAILING)" = "$(printf "alpha\nbeta\n")" ]'
check "run dir is owner-only" '[ "$(stat -f %Lp "$dir" 2>/dev/null || stat -c %a "$dir")" = 700 ]'

# ---- 2. nothing new: pre-existing failure only ---------------------------------
printf 'alpha\n' > FAILING
out="$(bash "$TEST" 2>/dev/null)"; rc=$?
check "exit 0 when the only failure is pre-existing" '[ "$rc" = 0 ]' "rc=$rc"
check "summary says new 0" 'grep -q "new 0" <<<"$out"' "$out"
printf 'alpha\nbeta\n' > FAILING

# ---- 3. no-baseline mode reports every failure --------------------------------
out="$(CONSORT_TEST_NO_BASELINE=1 bash "$TEST" 2>/dev/null)"; rc=$?
check "no-baseline: exit 1, both failures reported" '[ "$rc" = 1 ] && grep -q test_alpha <<<"$out" && grep -q test_beta <<<"$out"' "$out"
check "no-baseline: summary says so" 'grep -q "no baseline" <<<"$out"' "$out"
check "no-baseline: no worktree was made" '[ -z "$(git worktree list | grep -v "$R ")" ]'

# ---- 4. explicit base ref -----------------------------------------------------
git add -A; git commit -qm head
out="$(bash "$TEST" HEAD~1 2>/dev/null)"; rc=$?
check "branch-vs-base: compares against the named ref" '[ "$rc" = 1 ] && grep -q "new 1" <<<"$out"' "$out"
out="$(bash "$TEST" 2>/dev/null)"; rc=$?
check "committed head vs HEAD: nothing new" '[ "$rc" = 0 ] && grep -q "new 0" <<<"$out"' "$out"

# ---- 5. CONSORT_TEST_CMD override + failure-line cap ----------------------------
out="$(CONSORT_TEST_NO_BASELINE=1 CONSORT_TEST_MAX_LINES=1 CONSORT_TEST_CMD='bash test.sh' bash "$TEST" 2>/dev/null)"
check "MAX_LINES caps the listing and says how many more" 'grep -q "and 1 more" <<<"$out"' "$out"

# ---- 6. wall-clock cap ----------------------------------------------------------
touch SLEEP
start=$(date +%s)
out="$(CONSORT_TEST_TIMEOUT=2 CONSORT_TEST_NO_BASELINE=1 bash "$TEST" 2>"$T/err6")"; rc=$?
took=$(( $(date +%s) - start ))
check "timeout: exit 2, not a verdict" '[ "$rc" = 2 ]' "rc=$rc"
check "timeout: stderr says the suite did not complete" 'grep -q "did NOT complete" "$T/err6"' "$(cat "$T/err6")"
check "timeout: returned promptly" '[ "$took" -lt 15 ]' "${took}s"
rm -f SLEEP

# ---- 7. red head with no parseable failure line ---------------------------------
printf '' > FAILING; touch CRASH
out="$(CONSORT_TEST_NO_BASELINE=1 bash "$TEST" 2>/dev/null)"; rc=$?
check "crash: exit 1 even though no failure line matched" '[ "$rc" = 1 ]' "rc=$rc"
check "crash: points at the log tail" 'grep -q "no failure line matched" <<<"$out" && grep -q "Segmentation fault" <<<"$out"' "$out"
rm -f CRASH; git checkout -q -- FAILING

# ---- 8. refusals ----------------------------------------------------------------
bash "$TEST" -- 2>"$T/err8" >/dev/null; rc=$?
check "flag-shaped base ref refused (exit 2)" '[ "$rc" = 2 ] && grep -q "must not start with" "$T/err8"'
bash "$TEST" no-such-ref 2>"$T/err8b" >/dev/null; rc=$?
check "unknown base ref refused (exit 2)" '[ "$rc" = 2 ] && grep -q "not a commit" "$T/err8b"'
E="$T/empty"; mkdir -p "$E"; ( cd "$E" && git init -q . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m empty && bash "$TEST" ) 2>"$T/err8c" >/dev/null; rc=$?
check "no test command detected: exit 2, says the suite did not run" '[ "$rc" = 2 ] && grep -q "did NOT run" "$T/err8c"' "$(cat "$T/err8c")"
CONSORT_TEST_TIMEOUT=abc bash "$TEST" 2>"$T/err8d" >/dev/null; rc=$?
check "bad TIMEOUT refused (exit 2)" '[ "$rc" = 2 ] && grep -q CONSORT_TEST_TIMEOUT "$T/err8d"'

# ---- 9. failure-line parser covers the common runners ---------------------------
P="$T/parse.log"
cat > "$P" <<'LOG'
FAILED tests/test_a.py::test_x - AssertionError
ERROR tests/test_b.py
--- FAIL: TestFoo (0.00s)
test bar::baz ... FAILED
not ok 3 - qux
  ✕ renders (12 ms)
  1) suite does thing
PASSED tests/test_c.py
ok 4 - fine
  ✓ passes (3 ms)
LOG
out="$(CONSORT_TEST_NO_BASELINE=1 CONSORT_TEST_CMD="cat '$P'; exit 1" bash "$TEST" 2>/dev/null)"
cnt="$(sed -nE 's/.*head exit 1 \(([0-9]+) failing\).*/\1/p' <<<"$out")"
check "parser: 7 failure shapes matched, passes ignored" '[ "$cnt" = 7 ]' "matched $cnt"

echo
if [ "$fails" -eq 0 ]; then echo "consort-test.test.sh: all passed."; else echo "consort-test.test.sh: $fails FAILED"; exit 1; fi
