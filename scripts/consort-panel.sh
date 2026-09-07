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
#   CONSORT_PANEL_DIR   where leg results go (default: a fresh mktemp -d, kept).
#                       Stale <label>.json/.stderr/.exit for this run's legs are
#                       removed first — a previous run's file must never read as
#                       this run's verdict.
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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REVIEW="$ROOT/scripts/consort-review.sh"
BASE="${1:-}"
REVIEWERS="${CONSORT_REVIEWERS:-codex}"
TIMEOUT="${CONSORT_PANEL_TIMEOUT:-1800}"
case "$TIMEOUT" in ''|*[!0-9]*) echo "consort-panel: CONSORT_PANEL_TIMEOUT must be an integer number of seconds (got '$TIMEOUT')" >&2; exit 2 ;; esac

# ---- parse legs -------------------------------------------------------------
LABELS=(); SPECS=(); BACKENDS=(); ENVS=(); UNSETS=()
IFS=',' read -ra RAW <<< "$REVIEWERS"
for raw in ${RAW[@]+"${RAW[@]}"}; do
  spec="$(printf '%s' "$raw" | tr -d '[:space:]')"
  [ -n "$spec" ] || continue
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
DIR="${CONSORT_PANEL_DIR:-}"
if [ -n "$DIR" ]; then
  mkdir -p "$DIR" || { echo "consort-panel: cannot create CONSORT_PANEL_DIR=$DIR" >&2; exit 2; }
  DIR="$(cd "$DIR" && pwd -P)"
else
  DIR="$(mktemp -d)" || exit 2
fi
for l in "${LABELS[@]}"; do rm -f "$DIR/$l.json" "$DIR/$l.stderr" "$DIR/$l.exit" "$DIR/$l.start"; done

# ---- launch legs ------------------------------------------------------------
# Job control on: each background job gets its own process group, so a leg
# past its cap can be killed as a unit (the review script, its backend CLI,
# and whatever the CLI spawned) instead of orphaning a still-billing model
# call. Bash prints no job notices in a non-interactive shell.
set -m
PIDS=(); MODELS=()
leg_env_run() {  # <index> <command...> — runs a command under leg i's env
  local i="$1"; shift
  local -a e u
  IFS=$'\n' read -r -d '' -a e <<< "${ENVS[$i]}" || true
  IFS=$'\n' read -r -d '' -a u <<< "${UNSETS[$i]}" || true
  env ${u[@]+"${u[@]}"} "${e[@]}" "$@"
}
for i in "${!LABELS[@]}"; do
  l="${LABELS[$i]}"
  # Resolve the model string the way the leg itself will, for the manifest.
  MODELS+=("$(leg_env_run "$i" bash -c '. "$1/scripts/consort-backend.sh" 2>/dev/null; consort_impl_model 2>/dev/null' _ "$ROOT" || true)")
  date +%s > "$DIR/$l.start"
  (
    leg_env_run "$i" bash "$REVIEW" ${BASE:+"$BASE"} > "$DIR/$l.json" 2> "$DIR/$l.stderr"
    echo $? > "$DIR/$l.exit"
  ) &
  PIDS+=("$!")
  echo "consort-panel: [$l] started (${BACKENDS[$i]}, model ${MODELS[$i]:-?}, pid $!)" >&2
done

kill_all() { for p in ${PIDS[@]+"${PIDS[@]}"}; do kill -TERM -- "-$p" 2>/dev/null; done; }
trap 'kill_all; echo "consort-panel: interrupted, legs killed" >&2; exit 130' INT TERM

# ---- wait, enforcing the per-leg cap ----------------------------------------
while :; do
  pending=0; now="$(date +%s)"
  for i in "${!LABELS[@]}"; do
    l="${LABELS[$i]}"; p="${PIDS[$i]}"
    [ -f "$DIR/$l.exit" ] && continue
    if kill -0 "$p" 2>/dev/null; then
      if [ "$TIMEOUT" -gt 0 ] && [ $(( now - $(cat "$DIR/$l.start") )) -ge "$TIMEOUT" ]; then
        kill -TERM -- "-$p" 2>/dev/null; sleep 1; kill -KILL -- "-$p" 2>/dev/null
        wait "$p" 2>/dev/null
        [ -f "$DIR/$l.exit" ] || echo 124 > "$DIR/$l.exit"
        echo "consort-panel: [$l] killed after ${TIMEOUT}s (CONSORT_PANEL_TIMEOUT)" >&2
      else
        pending=1
      fi
    else
      # Process gone without writing an exit file (killed from outside): failed.
      wait "$p" 2>/dev/null
      [ -f "$DIR/$l.exit" ] || echo 143 > "$DIR/$l.exit"
    fi
  done
  [ "$pending" -eq 1 ] || break
  sleep 2
done
for p in "${PIDS[@]}"; do wait "$p" 2>/dev/null; done
trap - INT TERM

# ---- report -----------------------------------------------------------------
json_str() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n'; }
rc=0; any_excluded=0; legs_json=""
for i in "${!LABELS[@]}"; do
  l="${LABELS[$i]}"
  code="$(cat "$DIR/$l.exit" 2>/dev/null || echo 1)"
  secs=$(( $(date +%s) - $(cat "$DIR/$l.start") ))
  if [ -s "$DIR/$l.stderr" ]; then sed "s/^/[$l] /" "$DIR/$l.stderr" >&2; fi
  case "$code" in
    0)   if [ -s "$DIR/$l.json" ]; then status=ok; else status=failed; rc=3; fi ;;
    4)   status=excluded; any_excluded=1 ;;
    124) status=timeout; rc=3 ;;
    *)   status=failed; rc=3 ;;
  esac
  [ "$status" = ok ] || : > "$DIR/$l.json"   # never leave a non-result that parses as one
  n="$(node -e 'try{const f=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).findings;console.log(Array.isArray(f)?f.length:"?")}catch{console.log("?")}' "$DIR/$l.json" 2>/dev/null || echo '?')"
  echo "consort-panel: [$l] $status — exit $code, ${secs}s, findings: $n" >&2
  legs_json+="${legs_json:+,}{\"label\":\"$(json_str "$l")\",\"spec\":\"$(json_str "${SPECS[$i]}")\",\"backend\":\"$(json_str "${BACKENDS[$i]}")\",\"model\":\"$(json_str "${MODELS[$i]}")\",\"status\":\"$status\",\"exit\":$code,\"seconds\":$secs,\"file\":\"$(json_str "$DIR/$l.json")\"}"
done
[ "$rc" -ne 0 ] || [ "$any_excluded" -eq 0 ] || rc=4
manifest="{\"dir\":\"$(json_str "$DIR")\",\"exit\":$rc,\"legs\":[$legs_json]}"
printf '%s\n' "$manifest" | tee "$DIR/panel.json"
if [ "$rc" -eq 3 ]; then
  echo "consort-panel: at least one leg DID NOT produce a review — this is a FAILED panel, not a clean one; do not treat the other legs' results as the configured panel." >&2
fi
exit "$rc"
