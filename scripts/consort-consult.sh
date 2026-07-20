#!/usr/bin/env bash
# consort — read-only consult to sol (Codex) with a structured schema.
# Used for panel drafts, plan refutation, and interview divergent questions.
#
# Usage: consort-consult.sh <schema-file> <prompt> [workdir]
# Emits the schema-conforming JSON on stdout ({} on failure).
#
# Env: CONSORT_IMPL_MODEL (default gpt-5.6-sol)
#      CONSORT_CODEX_BACKEND (exec|plugin; default auto — see codex-backend.sh)
set -euo pipefail
SCHEMA="${1:?schema file required}"
PROMPT="${2:?prompt required}"
WORKDIR="${3:-$PWD}"

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/codex-backend.sh"

OUT="$(mktemp)"; trap 'rm -f "$OUT"' EXIT
consort_codex_call read-only "$SCHEMA" "$WORKDIR" "$PROMPT" "$OUT" || true
if [ -s "$OUT" ]; then cat "$OUT"; else echo '{}'; fi
