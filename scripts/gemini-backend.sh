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

# gemini-cli rewrites model ids. Measured 2026-09-07 on 0.58.0 with Vertex
# auth: `-m gemini-3.8-flash` ran gemini-3.5-flash. Its resolver treats any id
# ending in "flash" as the flash alias and, once the CLI's 3.5-flash GA flag is
# on (it is for Vertex/Gemini auth), replaces it with its own default; the
# session log was the only witness. The CLI's experimental
# dynamicModelConfiguration resolver passes unknown ids through untouched, so
# every cli invocation gets it via a throwaway SYSTEM settings file (the
# GEMINI_CLI_SYSTEM_SETTINGS_PATH hook) layered over whatever real system
# settings exist. User and workspace settings are never touched.
_consort_gemini_system_settings_default() {
  case "$(uname -s)" in
    Darwin)                  echo "/Library/Application Support/GeminiCli/settings.json" ;;
    MINGW*|MSYS*|CYGWIN*)    echo "${PROGRAMDATA:-C:/ProgramData}/gemini-cli/settings.json" ;;
    *)                       echo "/etc/gemini-cli/settings.json" ;;
  esac
}
# Writes the throwaway system settings to $1: the real system settings (JSONC
# allowed, as the CLI allows) plus the resolver flag. FAILS CLOSED: a system
# file that exists but cannot be read or parsed aborts the call rather than
# silently dropping an admin layer (tool exclusions, MCP allowlist, sandbox
# policy) from a run that may be --yolo.
_consort_gemini_write_settings() {
  local base="${GEMINI_CLI_SYSTEM_SETTINGS_PATH:-$(_consort_gemini_system_settings_default)}"
  python3 - "$base" "$1" <<'EOF'
import json, os, sys
base, out = sys.argv[1], sys.argv[2]

def strip_jsonc(text):
    # Remove // and /* */ comments outside strings; the CLI accepts them.
    res, i, n, in_str = [], 0, len(text), False
    while i < n:
        c = text[i]
        if in_str:
            res.append(c)
            if c == "\\" and i + 1 < n:
                res.append(text[i + 1]); i += 2; continue
            if c == '"':
                in_str = False
            i += 1; continue
        if c == '"':
            in_str = True; res.append(c); i += 1; continue
        if text.startswith("//", i):
            j = text.find("\n", i); i = n if j < 0 else j; continue
        if text.startswith("/*", i):
            j = text.find("*/", i + 2); i = n if j < 0 else j + 2; continue
        res.append(c); i += 1
    return "".join(res)

s = {}
if os.path.exists(base):
    try:
        with open(base) as fh:
            raw = fh.read()
        s = json.loads(strip_jsonc(raw)) if raw.strip() else {}
    except Exception as e:
        print(f"consort: gemini system settings {base} exist but could not be read/parsed "
              f"({type(e).__name__}); refusing to run the CLI without its admin layer", file=sys.stderr)
        sys.exit(1)
    if not isinstance(s, dict):
        print(f"consort: gemini system settings {base} are not a JSON object; refusing to run", file=sys.stderr)
        sys.exit(1)
s.setdefault("experimental", {})["dynamicModelConfiguration"] = True
with open(out, "w") as fh:
    json.dump(s, fh)
EOF
}

# Runs the gemini CLI once, with the throwaway settings, inside a subshell that
# owns an owner-only temp DIRECTORY and removes it on any exit (EXIT trap fires
# on Ctrl-C, timeout kill and set -e alike). A directory, not a file in
# $TMPDIR: the CLI derives its system-defaults path from the DIRNAME of the
# system settings path, so a bare file in a shared /tmp would make it load
# /tmp/system-defaults.json — pre-creatable by any local user, and settings
# feed mcpServers (child processes) and telemetry endpoints. The real
# system-defaults path is pinned explicitly for the same reason.
#   $1 = workdir ("" = stay put); rest = extra gemini args. Stdin passes through.
_consort_gemini_cli() {
  local workdir="$1"; shift
  (
    umask 077
    d="$(mktemp -d "${TMPDIR:-/tmp}/consort-gemini.XXXXXX")" || exit 1
    trap 'rm -rf "$d"' EXIT
    trap 'rm -rf "$d"; exit 130' INT TERM HUP
    _consort_gemini_write_settings "$d/settings.json" || exit 1
    if [ -n "$workdir" ]; then cd "$workdir" || exit 1; fi
    defaults="${GEMINI_CLI_SYSTEM_DEFAULTS_PATH:-$(dirname "${GEMINI_CLI_SYSTEM_SETTINGS_PATH:-$(_consort_gemini_system_settings_default)}")/system-defaults.json}"
    GOOGLE_GENAI_USE_VERTEXAI=true \
    GOOGLE_CLOUD_PROJECT="$(_consort_gemini_project)" \
    GOOGLE_CLOUD_LOCATION="$(_consort_gemini_location)" \
    GEMINI_CLI_TRUST_WORKSPACE=true \
    GEMINI_CLI_SYSTEM_SETTINGS_PATH="$d/settings.json" \
    GEMINI_CLI_SYSTEM_DEFAULTS_PATH="$defaults" \
    gemini --skip-trust --output-format json "$@"
  )
}

# Every cli call runs with --output-format json and is checked against the
# model it asked for. The envelope's stats name the model(s) that actually
# served the session; a run served by anything but the requested model is a
# swap, not a review, and is discarded loudly. Stdin: the envelope. $1: the
# requested model. Stdout: the model's final message. Stderr: one line of
# evidence (tool calls, tokens) — the "did the reviewer really run" check
# without opening the session log. Exit 2 on swap or no envelope.
_consort_gemini_unwrap() {
  # Script via -c, not `python3 -`: stdin carries the envelope, not the code.
  local script
  read -r -d '' script <<'EOF' || true
import json, sys
want = sys.argv[1]
raw = sys.stdin.read()
o = None
start = raw.find("{")
if start >= 0:
    try:
        o, _ = json.JSONDecoder().raw_decode(raw[start:])
    except Exception:
        o = None
if not isinstance(o, dict) or "response" not in o:
    print("consort: gemini CLI returned no --output-format json envelope"
          " — cannot prove which model ran; result discarded", file=sys.stderr)
    sys.exit(2)
if o.get("error"):
    # The formatter can attach a partial response to an error (stream cut,
    # output cap). A run the CLI itself marked failed is not a review, however
    # schema-shaped the fragment looks.
    print(f"consort: gemini CLI marked the run failed (error: {json.dumps(o['error'])[:300]}); "
          "partial response discarded", file=sys.stderr)
    sys.exit(2)
stats = o.get("stats") or {}
served = {}
for name, m in (stats.get("models") or {}).items():
    served[name[7:] if name.startswith("models/") else name] = (m or {}).get("tokens") or {}
tools = (stats.get("tools") or {}).get("totalCalls", 0)
# stats.models lists EVERY model that served a turn. A mid-run fallback (quota
# on the requested model, the CLI finishing on its flash default) leaves the
# requested id present next to the substitute, so membership is not enough:
# the requested model must be the only one that served main-role turns (helper
# roles, if the CLI ever reports any, do not author the verdict).
def main_turns(name):
    m = (stats.get("models") or {}).get(name) or (stats.get("models") or {}).get("models/" + name) or {}
    roles = m.get("roles") or {}
    if roles:
        return sum((r or {}).get("totalRequests", 0) for role, r in roles.items() if role == "main")
    return ((m.get("api") or {}).get("totalRequests")) or 1
authors = sorted(n for n in served if main_turns(n) > 0)
if authors != [want]:
    print(f"consort: gemini CLI answered with {authors or ['<none>']} where only the requested {want} "
          f"was allowed — model swap or mid-run fallback, not a review; result discarded", file=sys.stderr)
    sys.exit(2)
t = served[want]
print(f"consort: gemini {want} — {tools} tool calls, {t.get('input', 0)} input tokens "
      f"({t.get('cached', 0)} cached), {t.get('thoughts', 0)} thought tokens, "
      f"{t.get('candidates', 0)} output tokens", file=sys.stderr)
sys.stdout.write(o.get("response") or "")
EOF
  python3 -c "$script" "${1:?requested model}"
}

# One cheap round-trip so a caller can prove the reviewer actually answered
# (a zero-finding review and a dead backend look identical otherwise).
consort_gemini_probe() {
  local transport; transport="$(consort_gemini_transport)" || return 1
  if [ "$transport" = "cli" ]; then
    # The CLI's own stderr is noise (deprecation, ripgrep); the unwrap's is the
    # evidence line or the reason the probe failed, and stays visible.
    local model tok; model="$(_consort_gemini_model)"
    tok="$(_consort_gemini_cli "" -m "$model" -p "Reply with exactly: GEMINI_ALIVE" 2>/dev/null </dev/null \
      | _consort_gemini_unwrap "$model" | grep -o 'GEMINI_ALIVE' | head -1)"
    [ -n "$tok" ] && echo "$tok"
    [ -n "$tok" ]
  else
    local tok proj loc host
    tok="${CONSORT_GEMINI_TOKEN:-$(gcloud auth print-access-token 2>/dev/null)}"; proj="$(_consort_gemini_project)"; loc="$(_consort_gemini_location)"
    host="https://aiplatform.googleapis.com"; [ "$loc" != global ] && host="https://${loc}-aiplatform.googleapis.com"
    curl -s -X POST "$host/v1/projects/$proj/locations/$loc/publishers/google/models/$(_consort_gemini_model):generateContent" \
      -H "Authorization: Bearer $tok" -H "x-goog-user-project: $proj" -H "Content-Type: application/json" \
      -d '{"contents":[{"role":"user","parts":[{"text":"Reply with exactly: GEMINI_ALIVE"}]}],"generationConfig":{"maxOutputTokens":256}}' \
      2>/dev/null | grep -o 'GEMINI_ALIVE\|"finishReason"' | head -1 | sed 's/.*/GEMINI_ALIVE/'
    # A candidate with any finishReason (even MAX_TOKENS, which a thinking
    # model can hit before writing a word) proves reachability, auth and quota,
    # which is all a liveness probe is for.
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

  # Headless gemini answers from the prompt alone unless told otherwise: measured
  # 2026-09-07 (kvart PR #18 A/B), three review runs made zero tool calls and
  # missed the one HIGH that needed a caller sweep. Codex does the sweep on its
  # own; Gemini needs the instruction spelled out.
  local prompt
  prompt="$(
    printf '%s\n\n' "$sys"
    printf '<transport-note>\nYou are running inside the repository checkout with file-reading and search tools. Before your final answer you MUST use them: read the post-change version of every source file the diff touches; for every function, job, route, unit or symbol the diff removes or renames, search the repository for remaining callers, consumers, schedulers and documentation that depended on it; and perform any rule-pack checks that go beyond the diff. Do not answer from the diff alone. Backslash-escaped at-signs ("@") anywhere in this message are literal at-signs; the backslash only stops the CLI from treating them as file references.\n</transport-note>\n\n'
    if [ -n "$payload" ]; then printf '<stdin>\n'; cat "$payload"; printf '\n</stdin>\n\n'; fi
    printf '<output-contract>\nYour FINAL message must be exactly one JSON object conforming to this JSON Schema. No prose, no code fences, no tool chatter after it.\n'
    cat "$schema"
    printf '\n</output-contract>\n'
  )"
  # gemini-cli runs every prompt (stdin included) through its @-file expander:
  # `(?<!\\)@` + path chars. A unified diff's `@@` hunk headers match it, and
  # the fuzzy path resolver then injects unrelated repo files as "Content from
  # @@:" (observed: a systemd unit and a Vue component). A backslash before the
  # @ is the CLI's own escape, and headless mode passes text through without
  # un-escaping, so the model sees `\@`; the transport-note above explains it.
  prompt="${prompt//@/\\@}"

  # workspace-write auto-approves tools so the model can edit files (--yolo),
  # scoped to the workdir; read-only omits it so no writes happen.
  local write_flags=()
  [ "$mode" = "workspace-write" ] && write_flags=(--yolo)

  # Prompt (with a possibly large diff) goes on STDIN, not a -p arg, to avoid
  # ARG_MAX on big diffs. The runner's `cd || exit` aborts on a bad workdir
  # instead of running gemini in the wrong place, and its umask keeps the
  # stderr capture file (auth diagnostics) owner-only.
  local model raw resp; model="$(_consort_gemini_model)"
  raw="$(printf '%s' "$prompt" | \
    _consort_gemini_cli "$workdir" ${write_flags[@]+"${write_flags[@]}"} -m "$model" 2>>"${CONSORT_GEMINI_STDERR:-/dev/null}")"
  # The envelope proves which model served the run; a swap is discarded here,
  # so the caller sees an empty <out> (a FAILED call), never a wrong-model verdict.
  if ! resp="$(printf '%s' "$raw" | _consort_gemini_unwrap "$model")"; then
    if [ "$mode" = "workspace-write" ]; then
      # Attestation runs after the CLI exits; whatever served the rejected run
      # may already have edited the tree under --yolo. Nothing is reverted here
      # (the tree can hold the caller's own uncommitted work): say so, loudly.
      echo "consort: workspace-write run REJECTED after the fact — $workdir may carry edits from a model that was not the requested one; inspect \`git status\` / \`git diff\` there before trusting anything in it" >&2
    fi
    : > "$out"; return 0
  fi
  printf '%s' "$resp" | _consort_extract_json > "$out" 2>/dev/null || : > "$out"
  [ -s "$out" ] || return 0
}
