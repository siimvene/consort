#!/usr/bin/env bash
# consort — review panel: several cross-vendor reviewers on the same diff.
#
# Runs consort-review.sh once per reviewer "leg", in parallel, each leg on its
# own backend/provider/model, and writes one findings file per leg. One
# reviewer misses what another catches (SWE-chat: 93.4% of issues were caught
# by exactly one tool), so a gate that wants two vendors' readings runs them
# both, every time — this script is that "every time".
#
# Usage:
#   consort-panel.sh [base-ref]          # same target semantics as consort-review.sh
#
# Env:
#   CONSORT_REVIEWERS   comma-separated legs (default: codex). Grammar per leg:
#                         codex[:model]          -> CONSORT_BACKEND=codex, CONSORT_IMPL_MODEL
#                         gemini[:model]         -> CONSORT_BACKEND=gemini, CONSORT_GEMINI_MODEL
#                         pi[:provider[:model]]  -> CONSORT_BACKEND=pi, CONSORT_PI_PROVIDER/MODEL
#                       e.g. "codex,pi:google-vertex" = Codex CLI + Gemini through Pi.
#                       A leg that pins a provider but no model UNSETS any ambient
#                       CONSORT_PI_MODEL, so the provider's own default applies
#                       (an ambient gpt model on a google provider would be a
#                       guaranteed served-model mismatch, not a review).
#   CONSORT_PANEL_DIR   parent directory for results (default: mktemp -d). Every
#                       run creates its OWN fresh subdirectory in it (exclusive
#                       mkdir, named by timestamp and pid) and reports that path
#                       as "dir" in the manifest — so two panels sharing the same
#                       parent never see each other's files, and a previous
#                       run's manifest can never read as this run's verdict. The
#                       parent must be a directory the caller owns, not a symlink,
#                       not world-writable. Every file is created exclusively
#                       (noclobber, O_EXCL): a planted path is refused, never
#                       followed or truncated.
#   CONSORT_PANEL_TIMEOUT  wall-clock cap per leg in seconds (default 1800; 0 = none).
#                       A leg past its cap is killed (whole process group) and
#                       reported as "timeout", never as clean.
#
# Output:
#   stdout — one JSON manifest: {"dir":..., "legs":[{label,spec,backend,model,
#            status,exit,seconds,file}]}, also written to <dir>/panel.json.
#            status: ok | failed | timeout | excluded
#   stderr — every leg's stderr, prefixed "[label]" (that is where the backends'
#            evidence lines live: tool calls, tokens, served model), plus a
#            one-line summary per leg.
#   <dir>/<label>.json — that leg's {"findings":[...]} (empty on failure).
#   exit 0  every leg ok
#        2  bad CONSORT_REVIEWERS (unknown backend, duplicate leg, bad grammar) — nothing ran
#        3  at least one leg failed or timed out (the others' results are still on disk)
#        4  no leg failed but at least one exited 4 (all changed files excluded)
#
# A failed leg fails the panel. The gate rule is hard-fail, never degrade: a
# panel configured for two vendors that got one vendor's reading is not the
# panel that was configured, and the caller must know before believing it.
set -uo pipefail
# Every `>` in this script must create its file: an existing path — a stale
# result, a planted symlink — is an error, not something to follow or truncate.
set -o noclobber

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REVIEW="$ROOT/scripts/consort-review.sh"
BASE="${1:-}"
case "$BASE" in -*) echo "consort-panel: base ref must not start with '-' (got '$BASE')" >&2; exit 2 ;; esac
REVIEWERS="${CONSORT_REVIEWERS:-codex}"
TIMEOUT="${CONSORT_PANEL_TIMEOUT:-1800}"
case "$TIMEOUT" in ''|*[!0-9]*) echo "consort-panel: CONSORT_PANEL_TIMEOUT must be an integer number of seconds (got '$TIMEOUT')" >&2; exit 2 ;; esac

# ---- parse legs -------------------------------------------------------------
LABELS=(); SPECS=(); BACKENDS=(); ENVS=(); UNSETS=()
IFS=',' read -ra RAW <<< "$REVIEWERS"
for raw in ${RAW[@]+"${RAW[@]}"}; do
  spec="$(printf '%s' "$raw" | tr -d '[:space:]')"
  [ -n "$spec" ] || continue
  case "$spec" in *[[:cntrl:]]*) echo "consort-panel: leg spec contains control characters" >&2; exit 2 ;; esac
  case "$spec" in *::*|*:) echo "consort-panel: bad leg '$spec' (empty field)" >&2; exit 2 ;; esac
  IFS=':' read -r backend a b extra <<< "$spec"
  if [ -n "${extra:-}" ]; then
    echo "consort-panel: bad leg '$spec' (too many ':' fields)" >&2; exit 2
  fi
  envs=("CONSORT_BACKEND=$backend"); unsets=()
  case "$backend" in
    codex)
      [ -z "${b:-}" ] || { echo "consort-panel: bad leg '$spec' (codex takes at most one field: codex[:model])" >&2; exit 2; }
      [ -z "${a:-}" ] || envs+=("CONSORT_IMPL_MODEL=$a") ;;
    gemini)
      [ -z "${b:-}" ] || { echo "consort-panel: bad leg '$spec' (gemini takes at most one field: gemini[:model])" >&2; exit 2; }
      [ -z "${a:-}" ] || envs+=("CONSORT_GEMINI_MODEL=$a") ;;
    pi)
      if [ -n "${a:-}" ]; then
        envs+=("CONSORT_PI_PROVIDER=$a")
        if [ -n "${b:-}" ]; then envs+=("CONSORT_PI_MODEL=$b"); else unsets+=(-u CONSORT_PI_MODEL); fi
      elif [ -n "${b:-}" ]; then
        echo "consort-panel: bad leg '$spec' (a pi model needs a provider: pi:<provider>:<model>)" >&2; exit 2
      fi ;;
    *) echo "consort-panel: unknown backend in leg '$spec' (expected codex|gemini|pi)" >&2; exit 2 ;;
  esac
  # Label = the spec with ':' -> '-', restricted to a safe charset: it names
  # files in $DIR and appears verbatim in the manifest.
  label="$(printf '%s' "$spec" | tr ':' '-' | tr -c 'A-Za-z0-9._-' '_')"
  for l in ${LABELS[@]+"${LABELS[@]}"}; do
    [ "$l" != "$label" ] || { echo "consort-panel: duplicate leg '$spec'" >&2; exit 2; }
  done
  LABELS+=("$label"); SPECS+=("$spec"); BACKENDS+=("$backend")
  ENVS+=("$(printf '%s\n' "${envs[@]}")")
  UNSETS+=("$(printf '%s\n' ${unsets[@]+"${unsets[@]}"})")
done
[ "${#LABELS[@]}" -gt 0 ] || { echo "consort-panel: CONSORT_REVIEWERS names no leg" >&2; exit 2; }
[ -x "$REVIEW" ] || [ -f "$REVIEW" ] || { echo "consort-panel: missing $REVIEW" >&2; exit 2; }

# ---- result directory -------------------------------------------------------
PARENT="${CONSORT_PANEL_DIR:-}"
if [ -n "$PARENT" ]; then
  [ -e "$PARENT" ] || mkdir -p "$PARENT" || { echo "consort-panel: cannot create CONSORT_PANEL_DIR=$PARENT" >&2; exit 2; }
  # The panel creates files below here by name. The parent must be ours: a
  # directory another uid owns (a shared CI scratch, a pre-created /tmp name)
  # or one others can write into turns those names into their file handles.
  if [ -L "$PARENT" ] || [ ! -d "$PARENT" ] || [ ! -O "$PARENT" ]; then
    echo "consort-panel: CONSORT_PANEL_DIR must be a directory you own (not a symlink): $PARENT" >&2; exit 2
  fi
  if [ -n "$(find "$PARENT" -maxdepth 0 \( -perm -g+w -o -perm -o+w \) 2>/dev/null)" ]; then
    echo "consort-panel: CONSORT_PANEL_DIR is group- or world-writable, refusing: $PARENT" >&2; exit 2
  fi
  PARENT="$(cd "$PARENT" && pwd -P)"
else
  PARENT="$(mktemp -d)" || exit 2
fi
# One fresh, exclusively created directory per run: no stale leg file, no
# stale manifest, no two concurrent panels writing the same names.
DIR="$PARENT/panel-$(date -u +%Y%m%dT%H%M%SZ)-$$"
n=0; while ! mkdir -m 700 "$DIR" 2>/dev/null; do
  n=$((n+1)); [ "$n" -lt 100 ] || { echo "consort-panel: cannot create a run directory under $PARENT" >&2; exit 2; }
  DIR="$PARENT/panel-$(date -u +%Y%m%dT%H%M%SZ)-$$-$n"
done

# ---- launch legs ------------------------------------------------------------
# Job control on: each background job gets its own process group, so a leg
# past its cap can be killed as a unit (the review script, its backend CLI,
# and whatever the CLI spawned) instead of orphaning a still-billing model
# call. Bash prints no job notices in a non-interactive shell.
set -m
PIDS=(); MODELS=(); STARTS=()
leg_env_run() {  # <index> <command...> — runs a command under leg i's env
  local i="$1"; shift
  local -a e u
  IFS=$'\n' read -r -d '' -a e <<< "${ENVS[$i]}" || true
  IFS=$'\n' read -r -d '' -a u <<< "${UNSETS[$i]}" || true
  env ${u[@]+"${u[@]}"} "${e[@]}" "$@"
}
# Resolve every leg's model the way the leg itself will (for the manifest),
# and refuse two legs that resolve to the same backend + model: the same
# reviewer run twice would present its own findings as independent agreement.
for i in "${!LABELS[@]}"; do
  MODELS+=("$(leg_env_run "$i" bash -c '. "$1/scripts/consort-backend.sh" 2>/dev/null; consort_impl_model 2>/dev/null' _ "$ROOT" || true)")
  for j in "${!MODELS[@]}"; do
    [ "$j" -lt "$i" ] || continue
    if [ "${BACKENDS[$j]}|${MODELS[$j]}" = "${BACKENDS[$i]}|${MODELS[$i]}" ]; then
      echo "consort-panel: legs '${SPECS[$j]}' and '${SPECS[$i]}' resolve to the same reviewer (${BACKENDS[$i]} ${MODELS[$i]:-?})" >&2; exit 2
    fi
  done
done

# Cleanup is armed BEFORE the first leg starts and covers HUP (a dropped
# terminal or SSH session does not reach the legs' own process groups) and
# EXIT; a group that shrugs off TERM gets KILL a second later, but only
# while it still exists — a pgid can be recycled, and a blind KILL would hit
# whoever got it. A wrapper must never exit leaving a still-billing reviewer.
stop_groups() {  # <pid>... — TERM, grace, KILL-if-still-there
  local p; [ "$#" -gt 0 ] || return 0
  for p in "$@"; do kill -TERM -- "-$p" 2>/dev/null; done
  sleep 1
  for p in "$@"; do kill -0 -- "-$p" 2>/dev/null && kill -KILL -- "-$p" 2>/dev/null; done
  for p in "$@"; do wait "$p" 2>/dev/null; done
}
live_pids() { local p; for p in ${PIDS[@]+"${PIDS[@]}"}; do [ -n "$p" ] && printf '%s\n' "$p"; done; }
on_signal() { stop_groups $(live_pids); echo "consort-panel: interrupted, legs killed" >&2; trap - EXIT; exit 130; }
on_exit()   { stop_groups $(live_pids); }
trap on_signal INT TERM HUP
trap on_exit EXIT
for i in "${!LABELS[@]}"; do
  l="${LABELS[$i]}"
  # Start stamps stay in memory: a value read back from a file would be
  # substituted into $(( )) below, and bash expands array subscripts there —
  # file bytes like a[$(cmd)] would run cmd.
  STARTS+=("$(date +%s)")
  (
    leg_env_run "$i" bash "$REVIEW" ${BASE:+"$BASE"} > "$DIR/$l.json" 2> "$DIR/$l.stderr"
    echo $? > "$DIR/$l.exit"
  ) &
  PIDS+=("$!")
  echo "consort-panel: [$l] started (${BACKENDS[$i]}, model ${MODELS[$i]:-?}, pid $!)" >&2
done

# ---- wait, enforcing the per-leg cap ----------------------------------------
# A reaped pid is cleared from PIDS at once: a recycled pid would otherwise
# make the cleanup signal some unrelated process group of the same user.
# Legs that expire together are stopped together (one grace period, not one
# per leg), so the last of N hung legs does not overrun its cap by N seconds.
while :; do
  pending=0; now="$(date +%s)"; expired=()
  for i in "${!LABELS[@]}"; do
    l="${LABELS[$i]}"; p="${PIDS[$i]}"
    [ -n "$p" ] || continue
    if [ -f "$DIR/$l.exit" ]; then wait "$p" 2>/dev/null; PIDS[$i]=""; continue; fi
    if kill -0 "$p" 2>/dev/null; then
      if [ "$TIMEOUT" -gt 0 ] && [ $(( now - STARTS[i] )) -ge "$TIMEOUT" ]; then expired+=("$i"); else pending=1; fi
    else
      # The leg's leader died without writing an exit file (killed from
      # outside, OOM): failed — and its group (the backend CLI it spawned)
      # may still be running, so sweep it too.
      wait "$p" 2>/dev/null; PIDS[$i]=""
      kill -0 -- "-$p" 2>/dev/null && stop_groups "$p"
      [ -f "$DIR/$l.exit" ] || echo 143 > "$DIR/$l.exit" 2>/dev/null
      echo "consort-panel: [$l] died without a result (killed from outside?)" >&2
    fi
  done
  if [ "${#expired[@]}" -gt 0 ]; then
    pids=(); for i in "${expired[@]}"; do pids+=("${PIDS[$i]}"); done
    stop_groups "${pids[@]}"
    for i in "${expired[@]}"; do
      l="${LABELS[$i]}"; p="${PIDS[$i]}"; PIDS[$i]=""
      if kill -0 -- "-$p" 2>/dev/null; then
        echo "consort-panel: [$l] process group $p survived TERM+KILL — it may still be running (and billing); check it by hand" >&2
      fi
      [ -f "$DIR/$l.exit" ] || echo 124 > "$DIR/$l.exit" 2>/dev/null
      echo "consort-panel: [$l] killed after ${TIMEOUT}s (CONSORT_PANEL_TIMEOUT)" >&2
    done
  fi
  [ "$pending" -eq 1 ] || break
  sleep 2
done
for p in ${PIDS[@]+"${PIDS[@]}"}; do [ -n "$p" ] && wait "$p" 2>/dev/null; done
PIDS=()
trap - INT TERM HUP EXIT

# ---- report -----------------------------------------------------------------
rc=0; any_excluded=0; LEGARGS=()
for i in "${!LABELS[@]}"; do
  l="${LABELS[$i]}"
  code="$(cat "$DIR/$l.exit" 2>/dev/null)"
  # File bytes are data: only a plain integer is an exit code, anything else is a failure.
  case "$code" in ''|*[!0-9]*) code=1 ;; esac
  secs=$(( $(date +%s) - STARTS[i] ))
  if [ -s "$DIR/$l.stderr" ]; then sed "s/^/[$l] /" "$DIR/$l.stderr" >&2; fi
  case "$code" in
    0)   if [ -s "$DIR/$l.json" ]; then status=ok; else status=failed; rc=3; fi ;;
    4)   status=excluded; any_excluded=1 ;;
    124) status=timeout; rc=3 ;;
    *)   status=failed; rc=3 ;;
  esac
  if [ "$status" != ok ]; then rm -f "$DIR/$l.json"; : > "$DIR/$l.json"; fi   # never leave a non-result that parses as one
  n="$(node -e 'try{const f=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).findings;console.log(Array.isArray(f)?f.length:"?")}catch{console.log("?")}' "$DIR/$l.json" 2>/dev/null || echo '?')"
  echo "consort-panel: [$l] $status — exit $code, ${secs}s, findings: $n" >&2
  LEGARGS+=("$l" "${SPECS[$i]}" "${BACKENDS[$i]}" "${MODELS[$i]}" "$status" "$code" "$secs" "$DIR/$l.json")
done
[ "$rc" -ne 0 ] || [ "$any_excluded" -eq 0 ] || rc=4
# A real serializer: labels are sanitized, but dir/model strings are not.
manifest="$(node -e '
const [dir, rc, ...r] = process.argv.slice(1); const legs = [];
for (let i = 0; i < r.length; i += 8) legs.push({ label: r[i], spec: r[i+1], backend: r[i+2], model: r[i+3], status: r[i+4], exit: Number(r[i+5]), seconds: Number(r[i+6]), file: r[i+7] });
process.stdout.write(JSON.stringify({ dir, exit: Number(rc), legs }));' "$DIR" "$rc" "${LEGARGS[@]}")"
printf '%s\n' "$manifest" > "$DIR/panel.json" || echo "consort-panel: could not write $DIR/panel.json" >&2
printf '%s\n' "$manifest"
if [ "$rc" -eq 3 ]; then
  echo "consort-panel: at least one leg DID NOT produce a review — this is a FAILED panel, not a clean one; do not treat the other legs' results as the configured panel." >&2
fi
exit "$rc"
