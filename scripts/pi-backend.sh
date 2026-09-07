# consort — Pi backend (sourced, not executed).
#
# One CLI, every vendor. Pi (@earendil-works/pi-coding-agent) is a minimal
# multi-provider coding agent: Anthropic, OpenAI (API key or the ChatGPT/Codex
# subscription OAuth), Google Vertex (ADC / service-account key, no API key)
# and ~25 more, all behind the same headless JSON-lines protocol. Selected
# with CONSORT_BACKEND=pi (see consort-backend.sh). Whether a Pi run counts as
# CROSS-VENDOR depends on the provider you point it at, not on Pi: with the
# principal on Claude, `anthropic` is same-vendor and never satisfies the gate.
#
# Why it earns a backend of its own: every assistant message Pi emits carries
# the provider, the model id and the usage that served it. The served-model
# attestation the gemini-cli transport had to bolt on (0.7.1) is native here.
#
# Modes:
#   read-only       — tools limited to read,grep,find,ls; no user extensions,
#                     skills or prompt templates (non-inheriting context, like
#                     Codex's --ignore-user-config); project-local .pi files
#                     ignored (--no-approve) so a hostile repo cannot load an
#                     extension into its own reviewer. Repo AGENTS.md/CLAUDE.md
#                     stay in: that is the repo's own context, which Codex reads too.
#   workspace-write — full built-in tool set (read,bash,edit,write,grep,find,ls),
#                     Pi's default resource discovery. Pi has no OS sandbox: the
#                     tool allowlist and the workdir are the only fences, as with
#                     the gemini cli transport's --yolo. Same blast radius, same
#                     caution.
#
# Public API (mirrors codex-backend.sh / gemini-backend.sh):
#   consort_pi_backend   prints "pi" if usable, else fails.
#   consort_pi_probe     one cheap round-trip; prints PI_ALIVE when the
#                        requested provider+model answered (and only then).
#   consort_pi_call <mode> <schema> <workdir> <sys> <out> [payload]
#     On success writes a schema-shaped JSON object to <out>; on failure —
#     including a run served by any provider/model other than the requested
#     one — leaves <out> empty (callers treat that as a FAILED call).
#
# Env: CONSORT_PI_PROVIDER  (default openai-codex; google-vertex, openai,
#                            anthropic, google, ... — Pi's provider ids)
#      CONSORT_PI_MODEL     (default by provider: openai/openai-codex ->
#                            $CONSORT_IMPL_MODEL or gpt-5.6-sol; google* ->
#                            $CONSORT_GEMINI_MODEL or gemini-3.1-pro-preview;
#                            anthropic -> claude-opus-4-8)
#      CONSORT_PI_THINKING  (default high; off|minimal|low|medium|high|xhigh|max)
#      CONSORT_PI_STDERR    (file to append Pi's stderr to; dropped by default)
#      Provider auth is Pi's own: `pi auth check --provider <id>`; Vertex reads
#      GOOGLE_APPLICATION_CREDENTIALS / ADC + GOOGLE_CLOUD_PROJECT/LOCATION.

_consort_pi_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" && pwd; }
_consort_pi_provider() { echo "${CONSORT_PI_PROVIDER:-openai-codex}"; }
_consort_pi_model() {
  if [ -n "${CONSORT_PI_MODEL:-}" ]; then echo "$CONSORT_PI_MODEL"; return; fi
  case "$(_consort_pi_provider)" in
    openai|openai-codex) echo "${CONSORT_IMPL_MODEL:-gpt-5.6-sol}" ;;
    google*)             echo "${CONSORT_GEMINI_MODEL:-gemini-3.1-pro-preview}" ;;
    anthropic)           echo "claude-opus-4-8" ;;
    *)                   echo "${CONSORT_IMPL_MODEL:-gpt-5.6-sol}" ;;
  esac
}
_consort_pi_thinking() { echo "${CONSORT_PI_THINKING:-high}"; }

consort_pi_backend() {
  command -v pi >/dev/null || { echo "consort: pi backend needs the pi CLI (@earendil-works/pi-coding-agent) on PATH" >&2; return 1; }
  command -v python3 >/dev/null || { echo "consort: pi backend needs python3" >&2; return 1; }
  echo "pi"; return 0
}

# Reads Pi's --mode json event stream on stdin. $1 = requested provider,
# $2 = requested model. Every assistant message must have been served by
# exactly that pair — a substitution, a fallback, or a provider the caller
# never asked for is a swap, not a result. Stdout: the final assistant text.
# Stderr: one evidence line (turns, tool calls, tokens, cost) or the reason
# the run was discarded. Exit 2 on swap or no assistant message.
_consort_pi_unwrap() {
  local script
  read -r -d '' script <<'EOF' || true
import json, sys
want_p, want_m = sys.argv[1], sys.argv[2]
assistants, served, tools, final_text, errors = 0, set(), 0, None, []
usage = {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "reasoning": 0}
cost = 0.0
saw_any = False
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        o = json.loads(line)
    except Exception:
        continue
    saw_any = True
    t = o.get("type")
    if t == "tool_execution_start":
        tools += 1
    elif t == "extension_error":
        errors.append(str(o.get("error") or o)[:200])
    elif t == "message_end":
        m = o.get("message") or {}
        if m.get("role") != "assistant":
            continue
        assistants += 1
        served.add((m.get("provider"), m.get("model")))
        u = m.get("usage") or {}
        for k in usage:
            usage[k] += u.get(k, 0) or 0
        cost += ((u.get("cost") or {}).get("total") or 0)
        if m.get("errorMessage"):
            errors.append(str(m["errorMessage"])[:200])
        texts = [c.get("text") for c in (m.get("content") or []) if isinstance(c, dict) and c.get("type") == "text" and c.get("text")]
        if texts:
            final_text = "\n".join(texts)
        if m.get("stopReason") in ("error", "aborted"):
            errors.append(f"stopReason={m.get('stopReason')}")
if not saw_any:
    print("consort: pi produced no JSON event stream — cannot prove which model ran; result discarded", file=sys.stderr)
    sys.exit(2)
if assistants == 0:
    print("consort: pi run ended with no assistant message" + (f" (errors: {errors})" if errors else "") + "; result discarded", file=sys.stderr)
    sys.exit(2)
if served != {(want_p, want_m)}:
    print(f"consort: pi run was served by {sorted(f'{p}/{m}' for p, m in served)} where only the requested "
          f"{want_p}/{want_m} was allowed — model swap, not a result; discarded", file=sys.stderr)
    sys.exit(2)
if errors:
    print(f"consort: pi marked the run failed ({errors[-1]}); result discarded", file=sys.stderr)
    sys.exit(2)
print(f"consort: pi {want_p}/{want_m} — {assistants} turns, {tools} tool calls, {usage['input']} input tokens "
      f"({usage['cacheRead']} cached), {usage['reasoning']} reasoning tokens, {usage['output']} output tokens, "
      f"${cost:.4f}", file=sys.stderr)
sys.stdout.write(final_text or "")
EOF
  python3 -c "$script" "${1:?provider}" "${2:?model}"
}

# Pull the first balanced JSON object out of the model's final text.
_consort_pi_extract_json() {
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

# Runs Pi once in <workdir> ("" = stay put) with the given extra args; the
# prompt comes on stdin (Pi merges piped stdin into the initial message, so
# a diff of any size travels without touching ARG_MAX). Pi's stderr goes to
# $CONSORT_PI_STDERR, opened here after umask 077 so it is owner-only.
_consort_pi_run() {
  local workdir="$1"; shift
  (
    umask 077
    if [ -n "$workdir" ]; then cd "$workdir" || exit 1; fi
    pi -p --mode json --no-session "$@" 2>>"${CONSORT_PI_STDERR:-/dev/null}"
  )
}

consort_pi_probe() {
  local p m tok; p="$(_consort_pi_provider)"; m="$(_consort_pi_model)"
  tok="$(printf 'Reply with exactly: PI_ALIVE' | \
    _consort_pi_run "" --no-tools --no-extensions --no-skills --no-prompt-templates --no-themes --no-context-files --no-approve \
      --thinking off --system-prompt "Answer exactly as instructed." --provider "$p" --model "$m" \
    | _consort_pi_unwrap "$p" "$m" | grep -o 'PI_ALIVE' | head -1)"
  [ -n "$tok" ] && echo "$tok"
  [ -n "$tok" ]
}

consort_pi_call() {
  local mode="${1:?mode required}" schema="${2:?schema required}" workdir="${3:?workdir required}"
  local sys="${4:?sys prompt required}" out="${5:?out-file required}" payload="${6:-}"
  local p m; p="$(_consort_pi_provider)"; m="$(_consort_pi_model)"

  # Refuse a missing workdir — NEVER fall back to a broader directory: in
  # workspace-write Pi edits and runs shell commands wherever it is started.
  if [ ! -d "$workdir" ]; then
    echo "consort: pi workdir does not exist: $workdir" >&2
    : > "$out"; return 0
  fi

  local flags=(--provider "$p" --model "$m" --thinking "$(_consort_pi_thinking)")
  case "$mode" in
    read-only)
      flags+=(--tools read,grep,find,ls --no-extensions --no-skills --no-prompt-templates --no-themes --no-approve) ;;
    workspace-write)
      flags+=(--tools read,bash,edit,write,grep,find,ls) ;;
    *) echo "consort: pi backend: unknown mode '$mode'" >&2; : > "$out"; return 0 ;;
  esac

  # The caller's instructions ARE the system prompt (Pi's default coding
  # prompt is for an interactive assistant, not a structured reviewer);
  # context files and skills still append per Pi's contract. The payload and
  # the output contract travel as the user message on stdin.
  local prompt
  prompt="$(
    if [ -n "$payload" ]; then printf '<stdin>\n'; cat "$payload"; printf '\n</stdin>\n\n'; fi
    printf '<output-contract>\nYour FINAL message must be exactly one JSON object conforming to this JSON Schema. No prose before or after it, no code fences, no tool calls after it.\n'
    cat "$schema"
    printf '\n</output-contract>\n'
  )"

  local raw resp
  raw="$(printf '%s' "$prompt" | _consort_pi_run "$workdir" --system-prompt "$sys" ${flags[@]+"${flags[@]}"})"
  if ! resp="$(printf '%s' "$raw" | _consort_pi_unwrap "$p" "$m")"; then
    if [ "$mode" = "workspace-write" ]; then
      echo "consort: workspace-write run REJECTED after the fact — $workdir may carry edits from a run that was not served by the requested model; inspect \`git status\` / \`git diff\` there before trusting anything in it" >&2
    fi
    : > "$out"; return 0
  fi
  printf '%s' "$resp" | _consort_pi_extract_json > "$out" 2>/dev/null || : > "$out"
  [ -s "$out" ] || return 0
}
