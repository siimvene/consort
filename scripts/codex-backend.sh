# consort — Codex backend resolution + invocation (sourced, not executed).
#
# Two ways to reach the implementer:
#   exec    — the raw `codex exec` CLI (original bridge; schema-forced output)
#   plugin  — the official Codex Claude Code plugin's companion runtime
#             (scripts/codex-companion.mjs `task`), when installed. Uses the
#             plugin's shared runtime/session plumbing; the output schema is
#             enforced by prompt contract + local extraction instead of
#             --output-schema.
#
# Resolution order:
#   1. $CONSORT_CODEX_BACKEND if set to `exec` or `plugin` (hard override)
#   2. auto: exec when CONSORT_CODEX_HOMES is set (see below); else newest
#      codex-companion.mjs under ~/.claude/plugins/cache/*/codex/* with `node`
#      available -> plugin; else `codex` CLI -> exec
#
# Account failover (exec transport only):
#   CONSORT_CODEX_HOMES  ':'-separated CODEX_HOME directories, one per Codex
#                        account, tried in order. A call moves to the next
#                        account ONLY when the current one reports a usage or
#                        rate limit (read from codex's own error events, never
#                        from the transcript); any other failure stops the walk,
#                        since another account would fail the same way. A
#                        leading `~/` is expanded. Two tokens:
#                          @default    ${CODEX_HOME:-~/.codex}
#                          @termscape  every Codex account Termscape (nodeterm)
#                                      has signed in: its system account
#                                      (@default) first, then each managed
#                                      account's home under ~/.nodeterm/cx
#                        Homes without an auth.json are skipped; duplicates
#                        are tried once. Unset = today's single call on the
#                        inherited CODEX_HOME.
#   CONSORT_TERMSCAPE_DATA_DIR  Termscape's userData dir (default
#                        ~/Library/Application Support/node-terminal on macOS,
#                        ${XDG_CONFIG_HOME:-~/.config}/node-terminal elsewhere);
#                        NODETERM_CX_ROOT overrides the managed-home root, as
#                        it does in Termscape itself.
#   The plugin transport cannot fail over: its broker is started once under
#   whatever CODEX_HOME the first caller had and serves every later call on
#   that account. So a home list forces exec, and an explicit
#   CONSORT_CODEX_BACKEND=plugin with a home list is refused.
#   workspace-write calls fail over only when the limited attempt did no work
#   at all (no item in codex's event stream: no command, no file change, no
#   message) — the usual case, an account already at its limit, is refused on
#   the first request. Anything that started work stops the walk, so a
#   half-applied edit or a leftover background process is never handed to a
#   second account.
#   Evidence on stderr, one line per attempt: which home ran and how it ended.
#
# Public API (used by consort-consult.sh / consort-delegate.sh / consort-review.sh):
#   consort_codex_backend
#     Prints the resolved backend name ("plugin" or "exec"). Fails if neither
#     is available.
#   consort_codex_call <mode> <schema-file> <workdir> <sys-prompt> <out-file> [payload-file]
#     mode: read-only | workspace-write
#     Runs one Codex turn. The optional payload file is passed as the <stdin>
#     block (codex exec does this natively; the plugin path inlines it).
#     On success writes a schema-shaped JSON object to <out-file>; on failure
#     leaves <out-file> empty/absent (callers keep their own fallbacks).

_consort_companion_path() {
  # newest plugin version wins; glob covers marketplace-directory variations
  ls -d "$HOME"/.claude/plugins/cache/*/codex/*/scripts/codex-companion.mjs 2>/dev/null \
    | sort -V | tail -1
}

consort_codex_backend() {
  case "${CONSORT_CODEX_BACKEND:-auto}" in
    exec)   echo "exec"; return 0 ;;
    plugin)
      if [ -n "${CONSORT_CODEX_HOMES:-}" ]; then
        echo "consort: CONSORT_CODEX_HOMES needs the exec transport (the plugin broker is pinned to one account); unset CONSORT_CODEX_BACKEND=plugin or CONSORT_CODEX_HOMES" >&2
        return 1
      fi
      [ -n "$(_consort_companion_path)" ] || { echo "consort: CONSORT_CODEX_BACKEND=plugin but no codex-companion.mjs found" >&2; return 1; }
      command -v node >/dev/null || { echo "consort: plugin backend needs node" >&2; return 1; }
      echo "plugin"; return 0 ;;
    auto|*)
      if [ -n "${CONSORT_CODEX_HOMES:-}" ]; then
        command -v codex >/dev/null && { echo "exec"; return 0; }
        echo "consort: CONSORT_CODEX_HOMES is set but the codex CLI is not on PATH" >&2
        return 1
      fi
      if [ -n "$(_consort_companion_path)" ] && command -v node >/dev/null; then
        echo "plugin"; return 0
      fi
      command -v codex >/dev/null && { echo "exec"; return 0; }
      echo "consort: neither the Codex plugin runtime nor the codex CLI is available" >&2
      return 1 ;;
  esac
}

# ---- account failover ------------------------------------------------------
# A usage/rate-limit refusal, as codex's own error events and stderr word it
# (strings from codex-cli 0.158: "You've hit your usage limit", "Usage limit
# reached", "out of credits", usage_limit_reached, workspace_*_credits_depleted,
# rate_limit_reached; plus the HTTP 429 / insufficient_quota API shapes).
_CONSORT_CODEX_LIMIT_RE='usage[ _]limit|out of credits|credits_depleted|credit limit|rate[ _]limit|insufficient_quota|quota exceeded|too many requests|"status": ?429'

_consort_tilde() { case "$1" in "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac; }

_consort_termscape_data_dir() {
  if [ -n "${CONSORT_TERMSCAPE_DATA_DIR:-}" ]; then printf '%s' "${CONSORT_TERMSCAPE_DATA_DIR%/}"; return; fi
  case "$(uname -s)" in
    Darwin) printf '%s' "$HOME/Library/Application Support/node-terminal" ;;
    *)      printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/node-terminal" ;;
  esac
}

# Every Codex home Termscape has signed in, one per line: the system account,
# then each managed account at <cx root>/<sha256(userData \0 id)[:16]> — the
# same derivation as Termscape's codexAccountHome(). Pending (half-added)
# accounts are skipped; ids are held to Termscape's own id shape.
_consort_termscape_homes() {
  printf '%s\n' "${CODEX_HOME:-$HOME/.codex}"
  local data; data="$(_consort_termscape_data_dir)"
  [ -f "$data/settings.json" ] || { echo "consort: @termscape: no Termscape settings at $(_consort_tilde "$data")/settings.json (set CONSORT_TERMSCAPE_DATA_DIR)" >&2; return 0; }
  command -v node >/dev/null || { echo "consort: @termscape needs node to read Termscape's settings; using the system account only" >&2; return 0; }
  node - "$data" "${NODETERM_CX_ROOT:-$HOME/.nodeterm/cx}" <<'NODE' || echo "consort: @termscape: could not read $(_consort_tilde "$data")/settings.json; using the system account only" >&2
const fs = require("fs"), path = require("path"), crypto = require("crypto");
const [data, root] = process.argv.slice(2);
// A parse error must not reach stderr: node echoes the offending source line,
// and this file carries secrets (a gateway API key). Exit quietly instead.
let s;
try { s = JSON.parse(fs.readFileSync(path.join(data, "settings.json"), "utf8")); } catch { process.exit(1); }
for (const a of Array.isArray(s.codexAccounts) ? s.codexAccounts : []) {
  if (!a || a.pending || typeof a.id !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(a.id)) continue;
  const d = crypto.createHash("sha256").update(data).update("\0").update(a.id).digest("hex").slice(0, 16);
  console.log(path.join(root, d));
}
NODE
}

# CONSORT_CODEX_HOMES resolved to usable homes, in order, one per line.
_consort_codex_homes() {
  local raw entry cand real seen=""
  local -a entries
  IFS=':' read -ra entries <<< "${CONSORT_CODEX_HOMES:-}"
  for entry in ${entries[@]+"${entries[@]}"}; do
    case "$entry" in
      '') continue ;;
      @default)   raw="${CODEX_HOME:-$HOME/.codex}" ;;
      @termscape) raw="$(_consort_termscape_homes)" ;;
      @*) echo "consort: CONSORT_CODEX_HOMES: unknown token '$entry' (expected @default or @termscape)" >&2; continue ;;
      '~')  raw="$HOME" ;;
      '~/'*) raw="$HOME/${entry#'~/'}" ;;
      *)    raw="$entry" ;;
    esac
    while IFS= read -r cand; do
      [ -n "$cand" ] || continue
      # auth.json is the file store; a keyring-backed login has none, so
      # ask codex itself before skipping.
      if [ ! -f "$cand/auth.json" ] && ! { [ -d "$cand" ] && CODEX_HOME="$cand" codex login status </dev/null >/dev/null 2>&1; }; then
        echo "consort: skipping Codex home without a login: $(_consort_tilde "$cand")" >&2; continue
      fi
      real="$(cd "$cand" && pwd -P)" || continue
      case "$seen" in *"|$real|"*) continue ;; esac
      seen="$seen|$real|"
      printf '%s\n' "$cand"
    done <<< "$raw"
  done
}

# True when codex refused on a usage/rate limit. Only codex's error events
# (JSONL `error` / `turn.failed`) and its stderr are read — never item events,
# which carry the transcript: a review of code that mentions "usage limit"
# must not read as a limit.
_consort_codex_limited() {
  { LC_ALL=C grep -E '^\{"type":"(error|turn\.failed)"' "$1"; cat "$2"; } 2>/dev/null \
    | LC_ALL=C grep -Eiq "$_CONSORT_CODEX_LIMIT_RE"
}

_consort_codex_error_lines() {
  { LC_ALL=C grep -E '^\{"type":"(error|turn\.failed)"' "$1" 2>/dev/null || true; } | head -2 | cut -c1-300 | sed 's/^/consort:   /'
}

# Reduces codex's --json stream to what the walk needs: the error events
# verbatim, and one closing line counting the work items (commands, file
# changes, messages, reasoning; error notices excluded). The rest of the
# stream is the transcript (command output, repo content) and never touches
# disk. Items stream as they start, so a codex that died with none did no
# work; a missing count line (the filter itself killed) is treated as work.
_consort_codex_event_filter() {
  LC_ALL=C awk '
    /^\{"type":"(error|turn\.failed)"/ { print; next }
    /^\{"type":"item\./ && !/^\{"type":"item\.[a-z]+","item":\{"id":"[^"]*","type":"error"/ { n++ }
    END { printf "{\"type\":\"consort.work\",\"items\":%d}\n", n }'
}

# _consort_codex_exec_accounts <mode> <workdir> <out> <payload> <codex argv...>
# Runs the argv (which must carry --json and -o <out>) once, or once per
# account in CONSORT_CODEX_HOMES until one produces <out>. Always returns 0;
# an empty <out> is the caller's failure signal, as before.
_consort_codex_exec_accounts() {
  local mode="$1" workdir="$2" out="$3" payload="$4"; shift 4
  local in="${payload:-/dev/null}"
  if [ -z "${CONSORT_CODEX_HOMES:-}" ]; then
    "$@" < "$in" >/dev/null 2>&1 || true
    return 0
  fi
  local homes; homes="$(_consort_codex_homes)"
  if [ -z "$homes" ]; then
    echo "consort: CONSORT_CODEX_HOMES names no Codex home with a login — nothing ran" >&2
    : > "$out"; return 0
  fi
  local n; n="$(printf '%s\n' "$homes" | grep -c .)"
  local ev err home rc t0 items i=0
  ev="$(mktemp)"; err="$(mktemp)"
  while IFS= read -r home <&3; do
    i=$((i+1)); : > "$out"
    t0=$SECONDS
    # Status goes through a file so the walk survives a caller's
    # `set -euo pipefail` without a `|| true` around it.
    { CODEX_HOME="$home" "$@" < "$in" 2> "$err"; printf '%s' "$?" > "$err.rc"; } \
      | _consort_codex_event_filter > "$ev" || true
    rc="$(cat "$err.rc" 2>/dev/null || echo '?')"
    if [ -s "$out" ]; then
      echo "consort: codex account $i/$n ran the call: $(_consort_tilde "$home") ($((SECONDS-t0))s)" >&2
      break
    fi
    if ! _consort_codex_limited "$ev" "$err"; then
      echo "consort: codex account $i/$n failed without a usage limit: $(_consort_tilde "$home") (exit $rc) — not failing over, another account would fail the same way" >&2
      _consort_codex_error_lines "$ev" >&2
      break
    fi
    echo "consort: codex account $i/$n is at its usage limit: $(_consort_tilde "$home")" >&2
    if [ "$mode" = "workspace-write" ]; then
      items="$(sed -n 's/^{"type":"consort.work","items":\([0-9]*\)}$/\1/p' "$ev")"
      if [ "${items:-x}" != 0 ]; then
        echo "consort: not failing over a workspace-write call: the limited attempt had already started work (${items:-unknown} items) in $workdir — inspect \`git status\` there first" >&2
        break
      fi
    fi
    [ "$i" -lt "$n" ] || echo "consort: every Codex account in CONSORT_CODEX_HOMES is at its usage limit ($n tried)" >&2
  done 3<<< "$homes"
  rm -f "$ev" "$err" "$err.rc"
  return 0
}

# One cheap round-trip, walking the accounts like a real call; prints
# CODEX_ALIVE only when some account answered.
consort_codex_probe() {
  command -v codex >/dev/null || return 1
  local out; out="$(mktemp)"
  _consort_codex_exec_accounts read-only "$PWD" "$out" "" \
    codex exec -m "${CONSORT_IMPL_MODEL:-gpt-5.6-sol}" -s read-only --skip-git-repo-check \
    --json -o "$out" "Reply with exactly: CODEX_ALIVE"
  { grep -o 'CODEX_ALIVE' "$out" || true; } | head -1
  rm -f "$out"
}

consort_codex_call() {
  local mode="${1:?mode required}" schema="${2:?schema required}" workdir="${3:?workdir required}"
  local sys="${4:?sys prompt required}" out="${5:?out-file required}" payload="${6:-}"
  local model="${CONSORT_IMPL_MODEL:-gpt-5.6-sol}"
  # Empty first: a call refused below must not leave a previous run's result
  # looking like this one's.
  : > "$out"
  local backend; backend="$(consort_codex_backend)" || return 1

  if [ "$backend" = "exec" ]; then
    local sandbox="$mode"
    # Read-only calls (review/consult) run WITHOUT the user's ~/.codex/config.toml:
    # no plugins, plugin hooks, MCP servers or developer_instructions leak into
    # the reviewer's context (the non-inheriting-context axis), and the bill
    # stays proportional to the diff. Measured 2026-09-07 on a 25-file diff:
    # with the stock config the oh-my-codex plugin's prompt hook matched
    # "parallel mode" inside a rule pack, fanned the review out into three
    # subagents and re-prompted from its Stop hook — 10.7M input tokens, 909s;
    # with --ignore-user-config the same review took 2.46M tokens, 495s, same
    # real findings. Reasoning effort is pinned (CONSORT_CODEX_REASONING) because
    # the bypass also drops the user's setting.
    # Workspace-write (delegation) KEEPS the user config: that is where an
    # operator's [sandbox_workspace_write] narrowing and approval policy live.
    # CONSORT_CODEX_USER_CONFIG=1 keeps it for read-only calls too (needed e.g.
    # where config.toml carries a required [windows] sandbox selector). No
    # free-form flag passthrough: env-supplied argv after `-s` could revoke the
    # sandbox on a hostile checkout.
    # Native fan-out is a second cost multiplier the config bypass does not
    # touch: `codex exec` keeps its collaboration.spawn_agent tool even with
    # -c features.multi_agent=false (probed 2026-09-07), and the gate review
    # of this very change spawned three lanes unprompted (4.7M input tokens
    # for a 14KB diff). A reviewer has no use for lanes, so read-only calls
    # say so up front. A nudge, not a switch: unmeasured.
    local sys_eff="$sys"
    if [ "$mode" = "read-only" ]; then
      sys_eff="Work alone in this session: do not spawn, list or wait on collaboration agents; do every read and sweep yourself. $sys"
    fi
    local cfg=()
    if [ "$mode" = "read-only" ] && [ "${CONSORT_CODEX_USER_CONFIG:-0}" != "1" ]; then
      if codex exec --help 2>/dev/null | grep -q -- '--ignore-user-config'; then
        cfg=(--ignore-user-config -c "model_reasoning_effort=${CONSORT_CODEX_REASONING:-high}")
      else
        echo "consort: this codex CLI lacks --ignore-user-config; running the reviewer with the stock user config" >&2
      fi
    fi
    _consort_codex_exec_accounts "$mode" "$workdir" "$out" "$payload" \
      codex exec -m "$model" -s "$sandbox" -C "$workdir" --skip-git-repo-check \
      ${cfg[@]+"${cfg[@]}"} --json \
      --output-schema "$schema" -o "$out" "$sys_eff"
    return 0
  fi

  # plugin backend
  local companion; companion="$(_consort_companion_path)"
  local pf raw; pf="$(mktemp)" ; raw="$(mktemp)"
  {
    printf '%s\n' "$sys"
    if [ -n "$payload" ]; then
      printf '\n<stdin>\n'; cat "$payload"; printf '\n</stdin>\n'
    fi
    printf '\n<output-contract>\nYour FINAL message must be exactly one JSON object conforming to this JSON Schema. No prose before or after it, no code fences.\n'
    cat "$schema"
    printf '\n</output-contract>\n'
  } > "$pf"

  # ${arr[@]+...} idiom: safe under `set -u` on bash 3.2 (macOS) with empty arrays
  local write_flag=()
  [ "$mode" = "workspace-write" ] && write_flag=(--write)

  node "$companion" task --json --fresh --cwd "$workdir" --model "$model" \
    ${write_flag[@]+"${write_flag[@]}"} --prompt-file "$pf" > "$raw" 2>/dev/null || true

  # Extract the schema-shaped JSON object from the companion payload's rawOutput.
  node - "$raw" > "$out" 2>/dev/null <<'EXTRACT' || : > "$out"
const fs = require("fs");
const payload = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
let text = String(payload.rawOutput ?? "").trim();
const fence = text.match(/```(?:json)?\s*([\s\S]*?)```/);
if (fence) text = fence[1].trim();
const start = text.indexOf("{");
if (start < 0) process.exit(1);
// walk to the matching close brace of the first object
let depth = 0, end = -1, inStr = false, esc = false;
for (let i = start; i < text.length; i++) {
  const c = text[i];
  if (esc) { esc = false; continue; }
  if (c === "\\") { if (inStr) esc = true; continue; }
  if (c === '"') { inStr = !inStr; continue; }
  if (inStr) continue;
  if (c === "{") depth++;
  else if (c === "}") { depth--; if (depth === 0) { end = i; break; } }
}
if (end < 0) process.exit(1);
process.stdout.write(JSON.stringify(JSON.parse(text.slice(start, end + 1))));
EXTRACT

  rm -f "$pf" "$raw"
  [ -s "$out" ] || return 0   # callers handle the empty-result fallback
}
