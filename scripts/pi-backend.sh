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
#                     skills, prompt templates or context files (non-inheriting,
#                     like Codex's --ignore-user-config); project-local .pi
#                     files ignored (--no-approve). Context files are OFF here on
#                     purpose: Pi folds the workdir's AGENTS.md/CLAUDE.md — and
#                     every ancestor directory's, up to / — into the SYSTEM
#                     prompt. The rule packs the caller injects are the
#                     reviewer's brief; a repo that wants house rules in the
#                     review puts them in .claude/rules, which consort-review.sh
#                     fences as data.
#
# THE FENCE (pi-fence.mjs, a Pi extension loaded with -e on every run): Pi's
# own tools resolve any path — absolute, ../, ~ — and Pi has no OS sandbox,
# so the extension makes the workdir the boundary: every path argument of
# read/grep/find/ls/edit/write must resolve (symlinks followed) inside the
# workdir, and in read-only mode bash/edit/write are refused outright. Live-
# tested: ~/.zshrc, a symlink to $HOME inside the workdir, and `ls ..` all
# blocked; a file in the workdir read. bash in workspace-write is a shell and
# cannot be fenced here — the reason that mode is opt-in.
#   workspace-write — full built-in tool set (read,bash,edit,write,grep,find,ls),
#                     Pi's default discovery of the repo's context files and the
#                     user's extensions/skills; project-local .pi resources are
#                     still ignored (--no-approve): .pi/settings.json can set
#                     shellPath/shellCommandPrefix and .pi/extensions run code at
#                     startup, and a trust entry on a PARENT folder would apply
#                     it to every repo below. Pi has no OS sandbox: the tool
#                     allowlist and the workdir are the only fences, as with the
#                     gemini cli transport's --yolo. Same blast radius, same caution.
#
# Every run is --offline (no pi.dev version check / install telemetry) and
# needs ripgrep and fd resolvable up front: Pi's grep/find tools otherwise
# download an unpinned, unverified "latest" binary from GitHub on first use,
# which is not something a review should do on a fresh host.
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
#      CONSORT_PI_SAME_VENDOR_OK=1        allow provider=anthropic (principal is not Claude)
#      CONSORT_PI_UNSANDBOXED_WRITE_OK=1  allow workspace-write (no OS sandbox)
#      Provider auth is Pi's own: `pi auth check --provider <id>`; Vertex reads
#      GOOGLE_APPLICATION_CREDENTIALS / ADC + GOOGLE_CLOUD_PROJECT/LOCATION.
#      For google providers the consort-scoped names are honoured too, for
#      the Pi process only (the caller's shell is never touched), and WIN over
#      the ambient Google ones when set — they are the operator's explicit
#      choice for consort runs, e.g. a service-account key on a machine whose
#      user ADC is a workforce token that expires hourly:
#        CONSORT_GCP_PROJECT      -> GOOGLE_CLOUD_PROJECT   (same var the gemini backend uses)
#        CONSORT_GEMINI_LOCATION  -> GOOGLE_CLOUD_LOCATION  (same var the gemini backend uses)
#        CONSORT_GCP_CREDENTIALS  -> GOOGLE_APPLICATION_CREDENTIALS (a readable file, or the
#                                    backend refuses to start: a typo here must not fall
#                                    through to whatever ADC the shell happens to hold)

# Resolved at source time: BASH_SOURCE may be relative, and the runner cd's
# into the workdir before it needs this path.
_CONSORT_PI_FENCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pi-fence.mjs"
_consort_pi_provider() { echo "${CONSORT_PI_PROVIDER:-openai-codex}"; }
_consort_pi_model() {
  if [ -n "${CONSORT_PI_MODEL:-}" ]; then echo "$CONSORT_PI_MODEL"; return; fi
  case "$(_consort_pi_provider)" in
    openai|openai-codex) echo "${CONSORT_IMPL_MODEL:-gpt-5.6-sol}" ;;
    google*)             echo "${CONSORT_GEMINI_MODEL:-gemini-3.1-pro-preview}" ;;
    anthropic)           echo "claude-opus-4-8" ;;
    *) echo "consort: no default model for CONSORT_PI_PROVIDER=$(_consort_pi_provider); set CONSORT_PI_MODEL" >&2; return 1 ;;
  esac
}
_consort_pi_thinking() { echo "${CONSORT_PI_THINKING:-high}"; }

# Oldest Pi whose flags and JSON event contract this backend was written and
# tested against (--offline, --no-approve, --no-context-files, message_end
# provider/model/usage). An older CLI would silently lack a fence.
_CONSORT_PI_MIN_VERSION=0.84.0

consort_pi_backend() {
  command -v pi >/dev/null || { echo "consort: pi backend needs the pi CLI (@earendil-works/pi-coding-agent) on PATH" >&2; return 1; }
  command -v python3 >/dev/null || { echo "consort: pi backend needs python3" >&2; return 1; }
  local v; v="$(pi --version 2>/dev/null | head -1 | tr -d '[:space:]')"
  python3 -c '
import sys
def key(s): return tuple(int(x) for x in s.split("-")[0].split("."))
try: sys.exit(0 if key(sys.argv[1]) >= key(sys.argv[2]) else 1)
except Exception: sys.exit(1)' "$v" "$_CONSORT_PI_MIN_VERSION" \
    || { echo "consort: pi backend needs @earendil-works/pi-coding-agent >= $_CONSORT_PI_MIN_VERSION (found '${v:-none}')" >&2; return 1; }
  # Cross-vendor is the point of the gate. With the principal on Claude, an
  # anthropic provider is the same vendor reviewing itself; refuse unless the
  # operator states the principal is NOT Claude.
  if [ "$(_consort_pi_provider)" = anthropic ] && [ "${CONSORT_PI_SAME_VENDOR_OK:-}" != 1 ]; then
    echo "consort: CONSORT_PI_PROVIDER=anthropic is same-vendor for a Claude principal and does not satisfy the cross-vendor gate; set CONSORT_PI_SAME_VENDOR_OK=1 only if the principal is not Claude" >&2
    return 1
  fi
  _consort_pi_model >/dev/null || return 1
  if [ -n "${CONSORT_GCP_CREDENTIALS:-}" ] && [ ! -r "$CONSORT_GCP_CREDENTIALS" ]; then
    echo "consort: CONSORT_GCP_CREDENTIALS is set but not a readable file: $CONSORT_GCP_CREDENTIALS" >&2
    return 1
  fi
  # rg and fd (Debian ships fd as fdfind) on PATH, or already in Pi's own bin
  # (PI_CODING_AGENT_DIR overrides ~/.pi/agent).
  local pidir="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}" t alt
  for t in rg fd; do
    alt="$t"; [ "$t" = fd ] && alt=fdfind
    command -v "$t" >/dev/null 2>&1 || command -v "$alt" >/dev/null 2>&1 || [ -x "$pidir/bin/$t" ] \
      || { echo "consort: pi backend needs '$t' on PATH (ripgrep/fd) — Pi would otherwise fetch an unpinned binary from GitHub on first use; install it first" >&2; return 1; }
  done
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
served_response = set()
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
        # provider/model above are Pi's client-side echo of its own config.
        # Adapters that surface the server's answer (responseModel, OpenAI
        # completions today) get it checked too: it must name the requested
        # model, allowing a dated suffix (gpt-5.6-sol -> gpt-5.6-sol-2026-09-01).
        rm = m.get("responseModel")
        if rm:
            served_response.add(rm)
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
# Exact id, or the id with a dated deployment suffix (-YYYY-MM-DD); nothing
# else — "gpt-5-mini" must not pass for "gpt-5".
import re
ok_rm = re.compile(r"^(?:.*/)?" + re.escape(want_m) + r"(?:-\d{4}-\d{2}-\d{2})?$")
bad = sorted(r for r in served_response if not ok_rm.match(r))
if bad:
    print(f"consort: provider reported serving {bad} where the requested {want_m} was expected — "
          "server-side substitution, not a result; discarded", file=sys.stderr)
    sys.exit(2)
if errors:
    print(f"consort: pi marked the run failed ({errors[-1]}); result discarded", file=sys.stderr)
    sys.exit(2)
srv = f", served as {sorted(served_response)[0]}" if served_response else ""
print(f"consort: pi {want_p}/{want_m}{srv} — {assistants} turns, {tools} tool calls, {usage['input']} input tokens "
      f"({usage['cacheRead']} cached), {usage['reasoning']} reasoning tokens, {usage['output']} output tokens, "
      f"${cost:.4f}", file=sys.stderr)
sys.stdout.write(final_text or "")
EOF
  python3 -c "$script" "${1:?provider}" "${2:?model}"
}

# Pull the first balanced JSON object out of the model's final text and
# validate it against the schema (type, required, properties, items, enum,
# minimum/maximum, minLength — the subset consort's schemas use; no
# third-party validator is assumed). `{}` and `{"findings":null}` are
# syntactically valid objects that merge-findings.mjs would read as a
# clean verdict; they are not results.
_consort_pi_extract_json() {
  python3 -c "
import sys,json
schema=json.load(open(sys.argv[1])) if len(sys.argv)>1 else {}
def check(v, sc, path='$'):
    if not isinstance(sc, dict): return []
    errs=[]
    ty=sc.get('type')
    if ty:
        tys=ty if isinstance(ty,list) else [ty]
        okmap={'object':lambda x:isinstance(x,dict),'array':lambda x:isinstance(x,list),'string':lambda x:isinstance(x,str),
               'integer':lambda x:isinstance(x,int) and not isinstance(x,bool),'number':lambda x:isinstance(x,(int,float)) and not isinstance(x,bool),
               'boolean':lambda x:isinstance(x,bool),'null':lambda x:x is None}
        if not any(okmap.get(t,lambda x:True)(v) for t in tys): return [f'{path}: expected {ty}']
    if 'enum' in sc and v not in sc['enum']: errs.append(f'{path}: not in enum')
    if isinstance(v,dict):
        for k in sc.get('required') or []:
            if k not in v: errs.append(f'{path}.{k}: required')
        for k,sub in (sc.get('properties') or {}).items():
            if k in v: errs+=check(v[k],sub,f'{path}.{k}')
    if isinstance(v,list) and isinstance(sc.get('items'),dict):
        for i,it in enumerate(v): errs+=check(it,sc['items'],f'{path}[{i}]')
    if isinstance(v,str) and 'minLength' in sc and len(v)<sc['minLength']: errs.append(f'{path}: too short')
    if isinstance(v,(int,float)) and not isinstance(v,bool):
        if 'minimum' in sc and v<sc['minimum']: errs.append(f'{path}: below minimum')
        if 'maximum' in sc and v>sc['maximum']: errs.append(f'{path}: above maximum')
    return errs
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
o=json.loads(t[s:e+1])
errs=check(o,schema)
if errs:
    print('consort: pi result does not conform to the schema (%s); not a result' % '; '.join(errs[:5]), file=sys.stderr); sys.exit(1)
sys.stdout.write(json.dumps(o))
" "$@"
}

# Runs Pi once in <workdir> ("" = stay put) with the given extra args; the
# prompt comes on stdin (Pi merges piped stdin into the initial message, so
# a diff of any size travels without touching ARG_MAX). Pi's stderr goes to
# $CONSORT_PI_STDERR, opened here after umask 077 so it is owner-only.
_consort_pi_run() {
  local workdir="$1"; shift
  # Resolve the stderr capture path BEFORE cd, or a relative CONSORT_PI_STDERR
  # would land inside the (possibly untrusted, possibly ephemeral) workdir.
  # Create it owner-only, then run Pi under the user's own umask: a umask
  # around the whole process would also make every file the implementer
  # writes 0600.
  local errf="${CONSORT_PI_STDERR:-/dev/null}"
  case "$errf" in /*) ;; *) errf="$PWD/$errf" ;; esac
  [ "$errf" = /dev/null ] || ( umask 077; : >> "$errf" ) || return 1
  (
    if [ -n "$workdir" ]; then cd "$workdir" || exit 1; fi
    # Consort-scoped Google settings, exported for this Pi process only.
    case "$(_consort_pi_provider)" in
      google*)
        [ -z "${CONSORT_GCP_PROJECT:-}" ]     || export GOOGLE_CLOUD_PROJECT="$CONSORT_GCP_PROJECT"
        [ -z "${CONSORT_GEMINI_LOCATION:-}" ] || export GOOGLE_CLOUD_LOCATION="$CONSORT_GEMINI_LOCATION"
        [ -z "${CONSORT_GCP_CREDENTIALS:-}" ] || export GOOGLE_APPLICATION_CREDENTIALS="$CONSORT_GCP_CREDENTIALS" ;;
    esac
    # The fence extension (pi-fence.mjs) is loaded explicitly on every run;
    # --no-extensions in read-only disables DISCOVERY only, -e paths still load.
    CONSORT_PI_WORKDIR="${workdir:-$PWD}" CONSORT_PI_MODE="${CONSORT_PI_MODE:-read-only}" \
    pi -p --mode json --no-session --offline -e "$_CONSORT_PI_FENCE" "$@" 2>>"$errf"
  )
}

consort_pi_probe() {
  # The guards (CLI present and new enough, rg/fd, same-vendor refusal, model
  # default) live in consort_pi_backend; callers that skip consort_backend
  # must not skip them.
  consort_pi_backend >/dev/null || return 1
  local p m tok; p="$(_consort_pi_provider)"; m="$(_consort_pi_model)" || return 1
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
  # Same guards as the probe: consort-review.sh / consort-consult.sh call
  # consort_impl_call without consort_backend first.
  consort_pi_backend >/dev/null || { : > "$out"; return 0; }
  local p m; p="$(_consort_pi_provider)"; m="$(_consort_pi_model)" || { : > "$out"; return 0; }

  # Refuse a missing workdir — NEVER fall back to a broader directory: in
  # workspace-write Pi edits and runs shell commands wherever it is started.
  if [ ! -d "$workdir" ]; then
    echo "consort: pi workdir does not exist: $workdir" >&2
    : > "$out"; return 0
  fi
  # Absolute, symlink-free: the fence anchors on this string from inside the
  # workdir, where a relative path would resolve to the wrong place.
  workdir="$(cd "$workdir" && pwd -P)" || { : > "$out"; return 0; }

  local flags=(--provider "$p" --model "$m" --thinking "$(_consort_pi_thinking)")
  case "$mode" in
    read-only)
      flags+=(--tools read,grep,find,ls --no-extensions --no-skills --no-prompt-templates --no-themes --no-context-files --no-approve) ;;
    workspace-write)
      # No OS sandbox: bash/edit/write run with the user's full permissions
      # and accept paths outside the workdir, so the delegation contract
      # ("workspace-write cannot modify outside WORKDIR") cannot be enforced
      # here. Codex has a real sandbox; Pi does not. Explicit opt-in only.
      if [ "${CONSORT_PI_UNSANDBOXED_WRITE_OK:-}" != 1 ]; then
        echo "consort: pi workspace-write runs with NO sandbox (bash/edit/write, whole filesystem); set CONSORT_PI_UNSANDBOXED_WRITE_OK=1 to accept that, or delegate through the codex backend" >&2
        : > "$out"; return 0
      fi
      flags+=(--tools read,bash,edit,write,grep,find,ls --no-approve) ;;
    *) echo "consort: pi backend: unknown mode '$mode'" >&2; : > "$out"; return 0 ;;
  esac

  # The caller's instructions ARE the system prompt (Pi's default coding
  # prompt is for an interactive assistant, not a structured reviewer). The
  # payload and the output contract travel as the user message on stdin.
  local prompt
  prompt="$(
    if [ -n "$payload" ]; then printf '<stdin>\n'; cat "$payload"; printf '\n</stdin>\n\n'; fi
    printf '<output-contract>\nYour FINAL message must be exactly one JSON object conforming to this JSON Schema. No prose before or after it, no code fences, no tool calls after it.\n'
    cat "$schema"
    printf '\n</output-contract>\n'
  )"

  local raw resp
  raw="$(printf '%s' "$prompt" | CONSORT_PI_MODE="$mode" _consort_pi_run "$workdir" --system-prompt "$sys" ${flags[@]+"${flags[@]}"})"
  if ! resp="$(printf '%s' "$raw" | _consort_pi_unwrap "$p" "$m")"; then
    if [ "$mode" = "workspace-write" ]; then
      echo "consort: workspace-write run REJECTED after the fact — $workdir may carry edits from a run that was not served by the requested model; inspect \`git status\` / \`git diff\` there before trusting anything in it" >&2
    fi
    : > "$out"; return 0
  fi
  printf '%s' "$resp" | _consort_pi_extract_json "$schema" > "$out" || : > "$out"
  [ -s "$out" ] || return 0
}
