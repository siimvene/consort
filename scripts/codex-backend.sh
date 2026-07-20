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
#   2. auto: newest codex-companion.mjs under ~/.claude/plugins/cache/*/codex/*
#      with `node` available -> plugin; else `codex` CLI -> exec
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
      [ -n "$(_consort_companion_path)" ] || { echo "consort: CONSORT_CODEX_BACKEND=plugin but no codex-companion.mjs found" >&2; return 1; }
      command -v node >/dev/null || { echo "consort: plugin backend needs node" >&2; return 1; }
      echo "plugin"; return 0 ;;
    auto|*)
      if [ -n "$(_consort_companion_path)" ] && command -v node >/dev/null; then
        echo "plugin"; return 0
      fi
      command -v codex >/dev/null && { echo "exec"; return 0; }
      echo "consort: neither the Codex plugin runtime nor the codex CLI is available" >&2
      return 1 ;;
  esac
}

consort_codex_call() {
  local mode="${1:?mode required}" schema="${2:?schema required}" workdir="${3:?workdir required}"
  local sys="${4:?sys prompt required}" out="${5:?out-file required}" payload="${6:-}"
  local model="${CONSORT_IMPL_MODEL:-gpt-5.6-sol}"
  local backend; backend="$(consort_codex_backend)" || return 1

  if [ "$backend" = "exec" ]; then
    local sandbox="$mode"
    if [ -n "$payload" ]; then
      codex exec -m "$model" -s "$sandbox" -C "$workdir" --skip-git-repo-check \
        --output-schema "$schema" -o "$out" "$sys" < "$payload" >/dev/null 2>&1 || true
    else
      codex exec -m "$model" -s "$sandbox" -C "$workdir" --skip-git-repo-check \
        --output-schema "$schema" -o "$out" "$sys" >/dev/null 2>&1 || true
    fi
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
