#!/usr/bin/env bash
# consort — read-only consult to sol (Codex) with a structured schema.
# Used for panel drafts, plan refutation, and interview divergent questions.
#
# Usage: consort-consult.sh <schema-file> <prompt> [workdir]
# Emits the schema-conforming JSON on stdout ({} on failure).
#
# Env: CONSORT_IMPL_MODEL (default gpt-5.6-sol)
set -euo pipefail
MODEL="${CONSORT_IMPL_MODEL:-gpt-5.6-sol}"
SCHEMA="${1:?schema file required}"
PROMPT="${2:?prompt required}"
WORKDIR="${3:-$PWD}"

OUT="$(mktemp)"; trap 'rm -f "$OUT"' EXIT
codex exec -m "$MODEL" -s read-only -C "$WORKDIR" --skip-git-repo-check \
  --output-schema "$SCHEMA" -o "$OUT" "$PROMPT" >/dev/null 2>&1 || true
if [ -s "$OUT" ]; then cat "$OUT"; else echo '{}'; fi
