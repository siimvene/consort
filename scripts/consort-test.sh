#!/usr/bin/env bash
# consort-test — run the project's test suite OUT of the principal's context.
#
# Blast-surface step 5: run the suite, compare against a pre-change baseline on
# the same machine, any new failure is a finding. Done by hand in the principal's
# session, the whole test log lands in its context and every later turn re-reads
# it. This script keeps the logs on disk and prints only what the review needs:
# one summary line, the NEW failures (capped), and where the logs are.
#
# The baseline runs in a detached worktree of the base ref, so the working tree
# is never touched (no stash, no checkout). Dependency directories that a fresh
# checkout would lack (node_modules, .venv, venv, vendor) are symlinked from the
# workdir so the baseline suite can start.
#
# Running tests executes the diff's code. Trusted diffs only (your own work, or
# a branch you have read); for an untrusted diff, sandbox this or skip it and say
# so in the review.
#
# Usage: consort-test.sh [base-ref]
#   base-ref   the pre-change state (default HEAD: uncommitted vs the tip).
#
# Env:
#   CONSORT_TEST_CMD          suite command, run via `sh -c` in the tree under test.
#                             Default: detected — test.sh, package.json "test",
#                             pytest markers, go.mod, Cargo.toml, Makefile `test:`.
#                             Nothing detected: exit 2 and say so.
#   CONSORT_TEST_TIMEOUT      wall-clock cap per run, seconds (default 1800; 0 = none)
#   CONSORT_TEST_DIR          parent for the run directory (default: fresh mktemp -d);
#                             must be a directory you own, not group/world-writable
#   CONSORT_TEST_NO_BASELINE  =1: head run only; every failure is reported as new
#   CONSORT_TEST_MAX_LINES    cap on failure lines printed (default 40)
#
# Output (stdout, the only thing meant for the principal's context):
#   consort-test: <cmd> — head exit N (F failing), base exit M (G failing), new K
#   up to MAX_LINES new failure lines
#   log: <run dir>          (head.log, base.log, *.failures, result.json)
# Exit: 0 no new failures · 1 new failures · 2 could not run (no command, bad
#       ref, head timed out) · 3 baseline could not run (head result printed;
#       report it as unverified against a baseline, not as clean)
set -uo pipefail

BASE="${1:-HEAD}"
case "$BASE" in -*) echo "consort-test: base ref must not start with '-' (got '$BASE')" >&2; exit 2 ;; esac
TIMEOUT="${CONSORT_TEST_TIMEOUT:-1800}"
case "$TIMEOUT" in ''|*[!0-9]*) echo "consort-test: CONSORT_TEST_TIMEOUT must be an integer number of seconds (got '$TIMEOUT')" >&2; exit 2 ;; esac
MAX_LINES="${CONSORT_TEST_MAX_LINES:-40}"
case "$MAX_LINES" in ''|*[!0-9]*) echo "consort-test: CONSORT_TEST_MAX_LINES must be an integer (got '$MAX_LINES')" >&2; exit 2 ;; esac

WORKDIR="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "consort-test: not inside a git repository" >&2; exit 2; }
cd "$WORKDIR" || exit 2
git rev-parse --verify --quiet "${BASE}^{commit}" >/dev/null || { echo "consort-test: base ref '$BASE' is not a commit" >&2; exit 2; }

# ---- the suite command -------------------------------------------------------
detect_cmd() {
  if [ -f test.sh ]; then echo "bash test.sh"; return 0; fi
  if [ -f package.json ] && command -v node >/dev/null 2>&1 \
     && node -e 'const p=require(process.argv[1]);process.exit(p.scripts&&p.scripts.test?0:1)' "$PWD/package.json" 2>/dev/null; then
    echo "npm test --silent"; return 0
  fi
  if [ -f pytest.ini ] || [ -f conftest.py ] \
     || { [ -f pyproject.toml ] && grep -q pytest pyproject.toml; } \
     || { [ -f setup.cfg ] && grep -q '\[tool:pytest\]' setup.cfg; } \
     || { [ -f tox.ini ] && grep -q '\[pytest\]' tox.ini; }; then
    echo "python3 -m pytest -q -p no:cacheprovider"; return 0
  fi
  if [ -f go.mod ]; then echo "go test ./..."; return 0; fi
  if [ -f Cargo.toml ]; then echo "cargo test"; return 0; fi
  if [ -f Makefile ] && grep -qE '^test:' Makefile; then echo "make test"; return 0; fi
  return 1
}
CMD="${CONSORT_TEST_CMD:-}"
if [ -z "$CMD" ]; then
  CMD="$(detect_cmd)" || { echo "consort-test: no test command detected in $WORKDIR — set CONSORT_TEST_CMD (the suite did NOT run)" >&2; exit 2; }
fi

# ---- run directory ------------------------------------------------------------
PARENT="${CONSORT_TEST_DIR:-}"
if [ -n "$PARENT" ]; then
  [ -e "$PARENT" ] || mkdir -p "$PARENT" || { echo "consort-test: cannot create CONSORT_TEST_DIR=$PARENT" >&2; exit 2; }
  if [ -L "$PARENT" ] || [ ! -d "$PARENT" ] || [ ! -O "$PARENT" ]; then
    echo "consort-test: CONSORT_TEST_DIR must be a directory you own (not a symlink): $PARENT" >&2; exit 2
  fi
  if [ -n "$(find "$PARENT" -maxdepth 0 \( -perm -g+w -o -perm -o+w \) 2>/dev/null)" ]; then
    echo "consort-test: CONSORT_TEST_DIR is group- or world-writable, refusing: $PARENT" >&2; exit 2
  fi
  PARENT="$(cd "$PARENT" && pwd -P)"
else
  PARENT="$(mktemp -d)" || exit 2
fi
DIR="$PARENT/test-$(date -u +%Y%m%dT%H%M%SZ)-$$"
n=0; while ! mkdir -m 700 "$DIR" 2>/dev/null; do
  n=$((n+1)); [ "$n" -lt 100 ] || { echo "consort-test: cannot create a run directory under $PARENT" >&2; exit 2; }
  DIR="$PARENT/test-$(date -u +%Y%m%dT%H%M%SZ)-$$-$n"
done

BASE_TREE="$DIR/base"
cleanup() {
  if [ -d "$BASE_TREE" ]; then
    git -C "$WORKDIR" worktree remove --force "$BASE_TREE" >/dev/null 2>&1 || rm -rf "$BASE_TREE"
    git -C "$WORKDIR" worktree prune >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
trap 'cleanup; echo "consort-test: interrupted" >&2; trap - EXIT; exit 130' INT TERM

# ---- one capped run -----------------------------------------------------------
# Job control on for the launch so the suite gets its own process group and a
# run past its cap dies as a unit (the shell, the runner, whatever it forked).
# Writes the exit code to stdout: the suite's, 124 on timeout.
run_capped() {  # <tree> <log>
  local tree="$1" log="$2" pid start now
  set -m
  ( cd "$tree" && exec sh -c "$CMD" ) </dev/null >"$log" 2>&1 &
  pid=$!
  set +m
  start=$(date +%s)
  while kill -0 "$pid" 2>/dev/null; do
    now=$(date +%s)
    if [ "$TIMEOUT" -gt 0 ] && [ $((now - start)) -ge "$TIMEOUT" ]; then
      kill -TERM -- "-$pid" 2>/dev/null; sleep 1
      kill -KILL -- "-$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      echo "[consort-test: killed after ${TIMEOUT}s (CONSORT_TEST_TIMEOUT)]" >>"$log"
      echo 124; return
    fi
    sleep 1
  done
  wait "$pid"; echo $?
}

# ---- failure lines, normalised so base and head compare -----------------------
# One line per failing test across the common runners: pytest (FAILED/ERROR),
# jest/vitest/mocha (✕ ✗ × "N) name"), go (--- FAIL), cargo ("... FAILED"),
# TAP (not ok), and a bare FAIL/FAILED/ERROR at line start. Durations, ANSI
# colour and trailing whitespace are stripped so a slower run is not a new failure.
failures() {  # <log> -> <out>
  sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' "$1" \
    | grep -E '^[[:space:]]*(FAILED|FAIL|ERROR|not ok|✕|✗|×|--- FAIL)([[:space:]:]|$)|^[[:space:]]*[0-9]+\) |\.\.\. FAILED$' \
    | sed -E 's/[[:space:]]*\([0-9.]+ ?m?s\)//g; s/[[:space:]]+[0-9.]+ ?m?s$//; s/[[:space:]]+$//' \
    | sort -u >"$2"
}

# ---- head ---------------------------------------------------------------------
HEAD_EXIT="$(run_capped "$WORKDIR" "$DIR/head.log")"
failures "$DIR/head.log" "$DIR/head.failures"
HEAD_FAILING=$(wc -l <"$DIR/head.failures" | tr -d ' ')
if [ "$HEAD_EXIT" = 124 ]; then
  echo "consort-test: $CMD — head run killed after ${TIMEOUT}s; the suite did NOT complete (exit 2, not a verdict)" >&2
  echo "log: $DIR"
  exit 2
fi

# ---- baseline -----------------------------------------------------------------
BASE_STATUS="skipped" BASE_EXIT="" BASE_FAILING=""
if [ "${CONSORT_TEST_NO_BASELINE:-0}" != 1 ]; then
  if git worktree add --detach "$BASE_TREE" "$BASE" >"$DIR/worktree.log" 2>&1; then
    for dep in node_modules .venv venv vendor; do
      [ -e "$WORKDIR/$dep" ] && [ ! -e "$BASE_TREE/$dep" ] && ln -s "$WORKDIR/$dep" "$BASE_TREE/$dep"
    done
    BASE_EXIT="$(run_capped "$BASE_TREE" "$DIR/base.log")"
    failures "$DIR/base.log" "$DIR/base.failures"
    BASE_FAILING=$(wc -l <"$DIR/base.failures" | tr -d ' ')
    if [ "$BASE_EXIT" = 124 ]; then BASE_STATUS="timeout"; else BASE_STATUS="ok"; fi
  else
    BASE_STATUS="failed"
    echo "consort-test: could not check out base '$BASE' into a worktree — baseline MISSING:" >&2
    tail -n 3 "$DIR/worktree.log" >&2 || true
  fi
fi

# ---- new failures -------------------------------------------------------------
if [ "$BASE_STATUS" = ok ]; then
  comm -13 "$DIR/base.failures" "$DIR/head.failures" >"$DIR/new.failures"
else
  cp "$DIR/head.failures" "$DIR/new.failures"
fi
NEW=$(wc -l <"$DIR/new.failures" | tr -d ' ')

# ---- result.json (for the code-reviewer agent) --------------------------------
node -e '
const fs=require("fs"),[dir,cmd,base,hExit,hFail,bStatus,bExit,bFail]=process.argv.slice(1);
const lines=p=>fs.readFileSync(p,"utf8").split("\n").filter(Boolean);
const out={cmd,base_ref:base,dir,
  head:{exit:+hExit,failing:+hFail},
  baseline:{status:bStatus,exit:bExit===""?null:+bExit,failing:bFail===""?null:+bFail},
  new_failures:lines(dir+"/new.failures")};
fs.writeFileSync(dir+"/result.json",JSON.stringify(out,null,2)+"\n");
' "$DIR" "$CMD" "$BASE" "$HEAD_EXIT" "$HEAD_FAILING" "$BASE_STATUS" "$BASE_EXIT" "$BASE_FAILING" 2>/dev/null \
  || printf '{"cmd":"%s","dir":"%s","head":{"exit":%s,"failing":%s},"baseline":{"status":"%s"},"new_failures":"see new.failures"}\n' \
       "$CMD" "$DIR" "$HEAD_EXIT" "$HEAD_FAILING" "$BASE_STATUS" >"$DIR/result.json"

# ---- the only lines meant for the principal -----------------------------------
case "$BASE_STATUS" in
  ok)      base_txt="base exit $BASE_EXIT ($BASE_FAILING failing)" ;;
  timeout) base_txt="base run killed after ${TIMEOUT}s (baseline MISSING)" ;;
  failed)  base_txt="base checkout FAILED (baseline MISSING)" ;;
  *)       base_txt="no baseline (CONSORT_TEST_NO_BASELINE)" ;;
esac
echo "consort-test: $CMD — head exit $HEAD_EXIT ($HEAD_FAILING failing), $base_txt, new $NEW"
if [ "$NEW" -gt 0 ]; then
  head -n "$MAX_LINES" "$DIR/new.failures" | sed 's/^/  /'
  [ "$NEW" -gt "$MAX_LINES" ] && echo "  … and $((NEW - MAX_LINES)) more in $DIR/new.failures"
fi
if [ "$HEAD_EXIT" != 0 ] && [ "$HEAD_FAILING" = 0 ]; then
  echo "  head exited $HEAD_EXIT but no failure line matched — read the tail of head.log:"
  tail -n 5 "$DIR/head.log" | sed 's/^/  | /'
fi
echo "log: $DIR"

case "$BASE_STATUS" in timeout|failed) exit 3 ;; esac
if [ "$NEW" -gt 0 ]; then exit 1; fi
# Red head with nothing new parsed: red against a green (or absent) baseline is
# still a regression — a runner whose failures this script cannot read, or a
# crash before any test ran. Red against an equally red baseline is pre-existing.
if [ "$HEAD_EXIT" != 0 ]; then
  if [ "$BASE_STATUS" != ok ] || [ "$BASE_EXIT" = 0 ]; then exit 1; fi
fi
exit 0
