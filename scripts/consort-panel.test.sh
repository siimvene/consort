#!/usr/bin/env bash
# bash scripts/consort-panel.test.sh — pins consort-panel.sh against a stub
# consort-review.sh: leg grammar and env plumbing, parallel launch, per-leg
# result files, the hard-fail contract (one failed leg fails the panel, the
# others' results stay on disk), exit-4 propagation, the wall-clock cap, and
# stale-file removal. Runs the real panel script from a copied scripts/ dir
# so no test hook lives in the product script.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts"
cp "$HERE/consort-panel.sh" "$T/scripts/"
cat > "$T/scripts/consort-backend.sh" <<'STUB'
consort_impl_model() { echo "stub:${CONSORT_BACKEND:-codex}/${CONSORT_PI_PROVIDER:-}/${CONSORT_PI_MODEL:-}/${CONSORT_IMPL_MODEL:-}/${CONSORT_GEMINI_MODEL:-}"; }
STUB
cat > "$T/scripts/consort-review.sh" <<'STUB'
#!/usr/bin/env bash
# stub reviewer: behaviour keyed on STUB_* env; records the env it saw.
echo "saw backend=${CONSORT_BACKEND:-} provider=${CONSORT_PI_PROVIDER:-unset} model=${CONSORT_PI_MODEL:-unset} impl=${CONSORT_IMPL_MODEL:-unset} gem=${CONSORT_GEMINI_MODEL:-unset} base=${1:-none}" >&2
key="${CONSORT_BACKEND}:${CONSORT_PI_PROVIDER:-}"
case ",${STUB_SLEEP:-}," in *",$key,"*) sleep 30 ;; esac
case ",${STUB_FAIL:-}," in *",$key,"*) echo "stub: failed" >&2; exit 3 ;; esac
case ",${STUB_EXCLUDE:-}," in *",$key,"*) echo '{"findings":[]}'; exit 4 ;; esac
case ",${STUB_EMPTY_OK:-}," in *",$key,"*) exit 0 ;; esac
printf '{"findings":[{"file":"a.py","line":1,"severity":"low","title":"%s","detail":"d"}]}\n' "$key"
STUB
PANEL="$T/scripts/consort-panel.sh"
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1${2:+ — $2}"; fails=$((fails+1)); }
check() { if eval "$2"; then ok "$1"; else fail "$1" "$3"; fi; }
manifest_field() { node -e 'const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const l=m.legs.find(x=>x.label===process.argv[2]);console.log(l?String(l[process.argv[3]]):"")' "$1" "$2" "$3"; }

# 1. two legs, both ok
D="$T/r1"; out="$(CONSORT_REVIEWERS='codex,pi:google-vertex' CONSORT_PANEL_DIR="$D" bash "$PANEL" main 2>"$T/e1")"; rc=$?
check "two ok legs -> exit 0" '[ "$rc" -eq 0 ]' "rc=$rc $(cat "$T/e1")"
check "manifest written" '[ -s "$D/panel.json" ] && [ "$out" = "$(cat "$D/panel.json")" ]'
check "leg files present" '[ -s "$D/codex.json" ] && [ -s "$D/pi-google-vertex.json" ]'
check "codex leg saw its backend and the base ref" 'grep -q "saw backend=codex provider=unset .* base=main" "$T/e1"'
check "pi leg saw provider" 'grep -q "\[pi-google-vertex\] saw backend=pi provider=google-vertex" "$T/e1"'
check "manifest status ok" '[ "$(manifest_field "$D/panel.json" codex status)" = ok ] && [ "$(manifest_field "$D/panel.json" pi-google-vertex status)" = ok ]'
check "manifest model resolved under leg env" '[ "$(manifest_field "$D/panel.json" pi-google-vertex model)" = "stub:pi/google-vertex///" ]'
check "stderr summary per leg" 'grep -q "\[codex\] ok — exit 0" "$T/e1"'

# 2. ambient CONSORT_PI_MODEL is unset for a provider-pinned leg, kept for a bare pi leg, pinned by spec
D="$T/r2"; CONSORT_PI_MODEL=gpt-ambient CONSORT_REVIEWERS='pi:google-vertex,pi,pi:google-vertex:gemini-x' CONSORT_PANEL_DIR="$D" bash "$PANEL" >/dev/null 2>"$T/e2"; rc=$?
check "model env plumbing: exit 0" '[ "$rc" -eq 0 ]' "$(cat "$T/e2")"
check "provider-pinned leg unsets ambient model" 'grep -q "\[pi-google-vertex\] saw backend=pi provider=google-vertex model=unset" "$T/e2"'
check "bare pi leg inherits ambient model" 'grep -q "\[pi\] saw backend=pi provider=unset model=gpt-ambient" "$T/e2"'
check "spec model pins model" 'grep -q "\[pi-google-vertex-gemini-x\] saw backend=pi provider=google-vertex model=gemini-x" "$T/e2"'
D="$T/r2b"; CONSORT_REVIEWERS='codex:gpt-9,gemini:gem-9' CONSORT_PANEL_DIR="$D" bash "$PANEL" >/dev/null 2>"$T/e2b"
check "codex:model -> CONSORT_IMPL_MODEL" 'grep -q "\[codex-gpt-9\] saw backend=codex .* impl=gpt-9" "$T/e2b"'
check "gemini:model -> CONSORT_GEMINI_MODEL" 'grep -q "\[gemini-gem-9\] saw backend=gemini .* gem=gem-9" "$T/e2b"'

# 3. grammar errors: nothing runs, exit 2
for bad in 'codex,bogus' 'codex,codex' 'gemini:a:b' 'pi::m' 'codex:a:b' ', ,'; do
  D="$T/r3"; rm -rf "$D"
  CONSORT_REVIEWERS="$bad" CONSORT_PANEL_DIR="$D" bash "$PANEL" >/dev/null 2>"$T/e3"; rc=$?
  check "bad spec '$bad' -> exit 2, nothing ran" '[ "$rc" -eq 2 ] && ! ls "$D"/*.json >/dev/null 2>&1' "rc=$rc $(cat "$T/e3")"
done
CONSORT_REVIEWERS=codex CONSORT_PANEL_TIMEOUT=abc bash "$PANEL" >/dev/null 2>&1; rc=$?
check "non-numeric timeout -> exit 2" '[ "$rc" -eq 2 ]'

# 4. one leg fails -> panel exit 3, the other leg's result stays, failed leg's file is empty
D="$T/r4"; STUB_FAIL='pi:google-vertex' CONSORT_REVIEWERS='codex,pi:google-vertex' CONSORT_PANEL_DIR="$D" bash "$PANEL" >"$T/o4" 2>"$T/e4"; rc=$?
check "failed leg -> exit 3" '[ "$rc" -eq 3 ]' "rc=$rc"
check "failed leg status in manifest" '[ "$(manifest_field "$D/panel.json" pi-google-vertex status)" = failed ] && [ "$(manifest_field "$D/panel.json" codex status)" = ok ]'
check "good leg result kept" '[ -s "$D/codex.json" ]'
check "failed leg file empty" '[ -f "$D/pi-google-vertex.json" ] && [ ! -s "$D/pi-google-vertex.json" ]'
check "loud failure line" 'grep -q "FAILED panel" "$T/e4"'
check "manifest exit field" 'node -e "process.exit(JSON.parse(require(\"fs\").readFileSync(process.argv[1])).exit===3?0:1)" "$T/o4"'

# 5. exit 0 with empty stdout is a failed leg, not a clean one
D="$T/r5"; STUB_EMPTY_OK='codex:' CONSORT_REVIEWERS='codex' CONSORT_PANEL_DIR="$D" bash "$PANEL" >/dev/null 2>/dev/null; rc=$?
check "empty stdout on exit 0 -> failed" '[ "$rc" -eq 3 ] && [ "$(manifest_field "$D/panel.json" codex status)" = failed ]' "rc=$rc"

# 6. exit 4 propagates when nothing failed; a failure outranks it
D="$T/r6"; STUB_EXCLUDE='codex:' CONSORT_REVIEWERS='codex,pi:google-vertex' CONSORT_PANEL_DIR="$D" bash "$PANEL" >/dev/null 2>/dev/null; rc=$?
check "excluded leg -> exit 4" '[ "$rc" -eq 4 ] && [ "$(manifest_field "$D/panel.json" codex status)" = excluded ]' "rc=$rc"
D="$T/r6b"; STUB_EXCLUDE='codex:' STUB_FAIL='pi:google-vertex' CONSORT_REVIEWERS='codex,pi:google-vertex' CONSORT_PANEL_DIR="$D" bash "$PANEL" >/dev/null 2>/dev/null; rc=$?
check "excluded + failed -> exit 3" '[ "$rc" -eq 3 ]' "rc=$rc"

# 7. wall-clock cap: a hung leg is killed and reported as timeout; the other leg completes
D="$T/r7"; start=$(date +%s)
STUB_SLEEP='pi:google-vertex' CONSORT_PANEL_TIMEOUT=3 CONSORT_REVIEWERS='codex,pi:google-vertex' CONSORT_PANEL_DIR="$D" bash "$PANEL" >/dev/null 2>"$T/e7"; rc=$?
el=$(( $(date +%s) - start ))
check "timeout -> exit 3" '[ "$rc" -eq 3 ]' "rc=$rc"
check "timeout status" '[ "$(manifest_field "$D/panel.json" pi-google-vertex status)" = timeout ] && [ "$(manifest_field "$D/panel.json" pi-google-vertex exit)" = 124 ]'
check "timeout fired near the cap, not after the sleep" '[ "$el" -lt 20 ]' "took ${el}s"
check "other leg still ok" '[ "$(manifest_field "$D/panel.json" codex status)" = ok ]'
check "hung child is gone" '! pgrep -f "sleep 30" >/dev/null'

# 8. stale files for this run's legs are removed; unrelated files are kept
D="$T/r8"; mkdir -p "$D"; echo '{"findings":[{"file":"stale","line":1,"severity":"critical","title":"stale","detail":"d"}]}' > "$D/codex.json"; echo keep > "$D/other.json"
STUB_FAIL='codex:' CONSORT_REVIEWERS='codex' CONSORT_PANEL_DIR="$D" bash "$PANEL" >/dev/null 2>/dev/null
check "stale leg file replaced (failed -> empty)" '[ -f "$D/codex.json" ] && [ ! -s "$D/codex.json" ]'
check "unrelated file kept" '[ "$(cat "$D/other.json")" = keep ]'

# 9. default dir is a fresh mktemp dir that survives
out="$(CONSORT_REVIEWERS='codex' bash "$PANEL" 2>/dev/null)"; dir="$(node -e 'console.log(JSON.parse(process.argv[1]).dir)' "$out")"
check "default dir kept with results" '[ -s "$dir/codex.json" ]'; rm -rf "$dir"

# 10. merge consumes the panel's files directly
D="$T/r10"; CONSORT_REVIEWERS='codex,pi:google-vertex' CONSORT_PANEL_DIR="$D" bash "$PANEL" >/dev/null 2>/dev/null
echo '{"findings":[]}' > "$D/claude.json"
m="$(node "$HERE/merge-findings.mjs" "$D/claude.json" "$D"/codex.json "$D"/pi-google-vertex.json)"; rc=$?
check "merge of panel output" '[ "$rc" -eq 0 ] && printf "%s" "$m" | grep -q "Caught by more than one reviewer (1)"' "rc=$rc"

echo; if [ "$fails" -eq 0 ]; then echo "all green"; else echo "$fails FAILED"; exit 1; fi
