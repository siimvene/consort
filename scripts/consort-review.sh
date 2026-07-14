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
trap 'rm -f "$OUT"' EXIT

INSTRUCTIONS="You are a code reviewer. Review ONLY the unified diff provided on stdin for correctness bugs, security issues, and broken edge cases. Skip style nits. Report each concrete defect as a finding. If the diff is clean, return an empty findings array."

# stdin (the diff) is appended to the prompt as a <stdin> block by codex exec.
# read-only sandbox: Codex may read the repo but cannot modify anything.
# --output-schema forces the final message to match findings.schema.json.
printf '%s' "$DIFF" | codex exec \
  -m "$MODEL" \
  -s read-only \
  --skip-git-repo-check \
  --output-schema "$SCHEMA" \
  -o "$OUT" \
  "$INSTRUCTIONS" >/dev/null 2>&1 || true

if [ -s "$OUT" ]; then
  cat "$OUT"
else
  # Codex produced no schema-conforming final message (error, timeout, or refusal).
  echo '{"findings":[]}'
fi
