# consort — Gemini (Vertex AI) backend (sourced, not executed).
#
# A first-class peer to codex-backend.sh: a cross-vendor implementer+reviewer
# reached through Google's Gemini on Vertex AI via ADC (gcloud/WIF) — no API
# key, so it works where org policy disallows keys. Selected with
# CONSORT_BACKEND=gemini (see consort-backend.sh).
#
# TWO TRANSPORTS (like Codex's exec/plugin):
#   cli  — the `gemini` CLI (@google/gemini-cli) run IN the workdir. Like `codex
#          exec`, it reads the repo (repo-wide sweeps) and, in workspace-write
#          mode, edits files. Preferred when installed.
#   api  — the stdlib Vertex generateContent companion (gemini-companion.py):
#          diff-only, read-only, no repo access. Fallback for hosts without the
#          CLI (e.g. CI). Cannot do workspace-write.
#   Resolution: $CONSORT_GEMINI_TRANSPORT (cli|api) overrides; else auto
#   (cli if `gemini` on PATH, else api).
#
# Public API (mirrors codex-backend.sh):
#   consort_gemini_backend   prints "gemini" if usable, else fails.
#   consort_gemini_probe     one cheap round-trip; prints the model's reply.
#   consort_gemini_call <mode> <schema> <workdir> <sys> <out> [payload]
#     mode read-only     -> structured review/consult (cli or api)
#     mode workspace-write -> agentic implementer, edits files under <workdir>
#                             (cli only; api declines and leaves <out> empty)
#     On success writes a schema-shaped JSON object to <out>.
#
# Env: CONSORT_GEMINI_MODEL (default gemini-3.1-pro-preview),
#      CONSORT_GEMINI_LOCATION (global; europe-west4 for EU residency),
#      CONSORT_GCP_PROJECT (default: gcloud config project),
#      GEMINI_SANDBOX (optional; passed through to contain workspace-write).

_consort_gemini_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" && pwd; }
_consort_gemini_companion() { echo "$(_consort_gemini_dir)/gemini-companion.py"; }
_consort_gemini_model() { echo "${CONSORT_GEMINI_MODEL:-gemini-3.1-pro-preview}"; }
_consort_gemini_project() { echo "${CONSORT_GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null)}"; }
_consort_gemini_location() { echo "${CONSORT_GEMINI_LOCATION:-global}"; }

consort_gemini_transport() {
  case "${CONSORT_GEMINI_TRANSPORT:-auto}" in
    cli) command -v gemini >/dev/null && echo cli \
           || { echo "consort: CONSORT_GEMINI_TRANSPORT=cli but gemini CLI not on PATH" >&2; return 1; } ;;
    api) command -v python3 >/dev/null && echo api \
           || { echo "consort: CONSORT_GEMINI_TRANSPORT=api but python3 not on PATH" >&2; return 1; } ;;
    auto|*)
      if command -v gemini >/dev/null; then echo cli
      elif command -v python3 >/dev/null; then echo api
      else echo "consort: gemini backend needs the gemini CLI or python3" >&2; return 1; fi ;;
  esac
}

consort_gemini_backend() {
  local t; t="$(consort_gemini_transport)" || return 1
  # cli always needs ADC (gcloud); api can authenticate with CONSORT_GEMINI_TOKEN.
  if [ "$t" = cli ] || [ -z "${CONSORT_GEMINI_TOKEN:-}" ]; then
    command -v gcloud >/dev/null \
      || { echo "consort: gemini backend needs gcloud (ADC), or set CONSORT_GEMINI_TOKEN for the api transport" >&2; return 1; }
  fi
  echo "gemini"; return 0
}

# One cheap round-trip so a caller can prove the reviewer actually answered
# (a zero-finding review and a dead backend look identical otherwise).
consort_gemini_probe() {
  local transport; transport="$(consort_gemini_transport)" || return 1
  if [ "$transport" = "cli" ]; then
    GOOGLE_GENAI_USE_VERTEXAI=true \
    GOOGLE_CLOUD_PROJECT="$(_consort_gemini_project)" \
    GOOGLE_CLOUD_LOCATION="$(_consort_gemini_location)" \
    GEMINI_CLI_TRUST_WORKSPACE=true \
    gemini --skip-trust -m "$(_consort_gemini_model)" -p "Reply with exactly: GEMINI_ALIVE" 2>/dev/null \
      | grep -o 'GEMINI_ALIVE' | head -1
  else
    local tok proj loc host
    tok="${CONSORT_GEMINI_TOKEN:-$(gcloud auth print-access-token 2>/dev/null)}"; proj="$(_consort_gemini_project)"; loc="$(_consort_gemini_location)"
    host="https://aiplatform.googleapis.com"; [ "$loc" != global ] && host="https://${loc}-aiplatform.googleapis.com"
    curl -s -X POST "$host/v1/projects/$proj/locations/$loc/publishers/google/models/$(_consort_gemini_model):generateContent" \
      -H "Authorization: Bearer $tok" -H "x-goog-user-project: $proj" -H "Content-Type: application/json" \
      -d '{"contents":[{"role":"user","parts":[{"text":"Reply with exactly: GEMINI_ALIVE"}]}],"generationConfig":{"maxOutputTokens":16}}' \
      2>/dev/null | grep -o 'GEMINI_ALIVE' | head -1
  fi
}

# Pull the first balanced JSON object out of noisy CLI stdout (warnings, fences).
_consort_extract_json() {
  python3 -c "
import sys,json
t=sys.stdin.read()
s=t.find('{')
if s<0: sys.exit(1)
d=0; instr=False; esc=False; e=-1
for i in range(s,len(t)):
    c=t[i]
    if esc: esc=False; continue
    if c=='\\\\':
        if instr: esc=True
        continue
    if c=='\"': instr=not instr; continue
    if instr: continue
    if c=='{': d+=1
    elif c=='}':
        d-=1
        if d==0: e=i; break
if e<0: sys.exit(1)
sys.stdout.write(json.dumps(json.loads(t[s:e+1])))
"
}

consort_gemini_call() {
  local mode="${1:?mode required}" schema="${2:?schema required}" workdir="${3:?workdir required}"
  local sys="${4:?sys prompt required}" out="${5:?out-file required}" payload="${6:-}"

  local transport; transport="$(consort_gemini_transport)" || { : > "$out"; return 0; }

  if [ "$mode" = "workspace-write" ] && [ "$transport" != "cli" ]; then
    echo "consort: gemini api transport is read-only; workspace-write needs the gemini CLI" >&2
    : > "$out"; return 0
  fi

  # api transport: read-only structured review only.
  if [ "$transport" = "api" ]; then
    local args=(--schema "$schema" --out "$out")
    [ -n "$payload" ] && args+=(--payload "$payload")
    printf '%s' "$sys" | python3 "$(_consort_gemini_companion)" "${args[@]}" >/dev/null 2>&1 || true
    [ -s "$out" ] || return 0
    return 0
  fi

  # cli transport (read-only OR workspace-write): gemini runs in the workdir.
  # Refuse if the workdir is missing — NEVER fall back to a broader directory.
  # (Running the --yolo agentic editor outside the intended tree, e.g. in /, is
  # a blast-radius hazard.)
  if [ ! -d "$workdir" ]; then
    echo "consort: gemini workdir does not exist: $workdir" >&2
    : > "$out"; return 0
  fi

  local prompt
  prompt="$(
    printf '%s\n\n' "$sys"
    if [ -n "$payload" ]; then printf '<stdin>\n'; cat "$payload"; printf '\n</stdin>\n\n'; fi
    printf '<output-contract>\nYour FINAL message must be exactly one JSON object conforming to this JSON Schema. No prose, no code fences, no tool chatter after it.\n'
    cat "$schema"
    printf '\n</output-contract>\n'
  )"

  # workspace-write auto-approves tools so the model can edit files (--yolo),
  # scoped to the workdir; read-only omits it so no writes happen.
  local write_flags=()
  [ "$mode" = "workspace-write" ] && write_flags=(--yolo)

  # Prompt (with a possibly large diff) goes on STDIN, not a -p arg, to avoid
  # ARG_MAX on big diffs. `cd || exit` aborts the subshell on a bad workdir
  # instead of running gemini in the wrong place.
  local raw
  raw="$(
    cd "$workdir" || exit 0
    printf '%s' "$prompt" | \
    GOOGLE_GENAI_USE_VERTEXAI=true \
    GOOGLE_CLOUD_PROJECT="$(_consort_gemini_project)" \
    GOOGLE_CLOUD_LOCATION="$(_consort_gemini_location)" \
    GEMINI_CLI_TRUST_WORKSPACE=true \
    gemini --skip-trust ${write_flags[@]+"${write_flags[@]}"} -m "$(_consort_gemini_model)" 2>/dev/null
  )"
  printf '%s' "$raw" | _consort_extract_json > "$out" 2>/dev/null || : > "$out"
  [ -s "$out" ] || return 0
}
