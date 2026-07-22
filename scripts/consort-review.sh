#!/usr/bin/env bash
# consort: get Codex's structured review of the current working diff.
#
# Emits a JSON object {"findings":[...]} conforming to schemas/findings.schema.json
# to stdout, for scripts/merge-findings.mjs to diff against Claude's own findings.
#
# Usage:
#   consort-review.sh              # review uncommitted changes vs HEAD
#   consort-review.sh main         # review this branch vs origin/main..HEAD
#
# Env:
#   CONSORT_IMPL_MODEL   codex model (default: gpt-5.6-sol)
#   CONSORT_RULE_PACKS   colon-separated files/dirs of .md/.mdc rule packs; injected
#                        into the reviewer prompt so both sides review against the
#                        same written standard (packs stay in the org's repo, not here)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL="${CONSORT_IMPL_MODEL:-gpt-5.6-sol}"
SCHEMA="$ROOT/schemas/findings.schema.json"
BASE="${1:-}"

if [ -n "$BASE" ]; then
  DIFF="$(git diff "${BASE}...HEAD")"
else
  DIFF="$(git diff HEAD)"
fi

if [ -z "${DIFF//[[:space:]]/}" ]; then
  echo '{"findings":[]}'
  exit 0
fi

OUT="$(mktemp)"
DIFF_FILE="$(mktemp)"
trap 'rm -f "$OUT" "$DIFF_FILE"' EXIT
printf '%s' "$DIFF" > "$DIFF_FILE"

INSTRUCTIONS="You are a code reviewer. Review ONLY the unified diff provided in the stdin block for correctness bugs, security issues, and broken edge cases. Skip style nits. Report each concrete defect as a finding. If the diff is clean, return an empty findings array."

# Shared rubric: inject rule packs so this reviewer and the principal review
# against the same written standard. 64KB cap keeps a fat pack set from eating
# the reviewer's context; the cut is loud, not silent.
# Default resolution: when CONSORT_RULE_PACKS is unset, a repo-local
# .claude/rules/ directory (vendored packs) is used automatically.
if [ -z "${CONSORT_RULE_PACKS:-}" ] && [ -d "$PWD/.claude/rules" ]; then
  CONSORT_RULE_PACKS="$PWD/.claude/rules"
fi
PACKS=""
if [ -n "${CONSORT_RULE_PACKS:-}" ]; then
  IFS=':' read -ra PACK_PATHS <<< "$CONSORT_RULE_PACKS"
  for p in "${PACK_PATHS[@]}"; do
    [ -z "$p" ] && continue
    if [ -d "$p" ]; then
      while IFS= read -r f; do
        PACKS+="$(printf '\n\n=== rule pack: %s ===\n' "$f")$(cat "$f")"
      done < <(find "$p" -maxdepth 2 -type f \( -name '*.md' -o -name '*.mdc' \) | sort)
    elif [ -f "$p" ]; then
      PACKS+="$(printf '\n\n=== rule pack: %s ===\n' "$p")$(cat "$p")"
    else
      echo "consort-review: rule pack path not found: $p" >&2
    fi
  done
fi
if [ -n "$PACKS" ]; then
  if [ "${#PACKS}" -gt 65536 ]; then
    echo "consort-review: rule packs exceed 64KB, truncating — trim CONSORT_RULE_PACKS" >&2
    PACKS="${PACKS:0:65536}"$'\n[rule packs truncated at 64KB]'
  fi
  INSTRUCTIONS+=" Additionally review the diff against the following rule packs; when a finding violates a pack rule, name that rule in the finding title.${PACKS}"
fi

# read-only sandbox: Codex may read the repo but cannot modify anything.
# The diff travels as the <stdin> block; the schema is enforced by the backend
# (--output-schema on exec, prompt contract + extraction on the plugin runtime).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/codex-backend.sh"
consort_codex_call read-only "$SCHEMA" "$PWD" "$INSTRUCTIONS" "$OUT" "$DIFF_FILE" || true

if [ -s "$OUT" ]; then
  cat "$OUT"
else
  # Codex produced no schema-conforming final message (error, timeout, or refusal).
  echo '{"findings":[]}'
fi
