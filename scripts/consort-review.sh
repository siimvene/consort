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
