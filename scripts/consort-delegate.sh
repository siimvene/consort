#!/usr/bin/env bash
# consort Slice 0 — the delegation spine.
#
# Fable calls this to hand ONE task to sol (Codex) and get a structured result
# back. All the handoff state lands in <workdir>/.consort/ so any phase is
# resumable from disk and Fable's context is not the source of truth.
#
# Usage:
#   consort-delegate.sh <task-id> <brief-file> [workdir]
#     task-id     short slug, names the handoff files
#     brief-file  markdown with the five-part brief:
#                 Goal / Paths / Constraints / Definition of done / Return format
#     workdir     repo the task runs in (default: $PWD)
#
# Writes:
#   <workdir>/.consort/tasks/<task-id>.brief.md    copy of the brief handed over
#   <workdir>/.consort/tasks/<task-id>.result.json sol's structured return
#   <workdir>/.consort/log.jsonl                   append-only delegation log
#
# Env:
#   CONSORT_IMPL_MODEL   implementer model (default: gpt-5.6-sol)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL="${CONSORT_IMPL_MODEL:-gpt-5.6-sol}"
SCHEMA="$ROOT/schemas/task-result.schema.json"

TASK_ID="${1:?task-id required}"
BRIEF_FILE="${2:?brief-file required}"
WORKDIR="${3:-$PWD}"

[ -f "$BRIEF_FILE" ] || { echo "brief file not found: $BRIEF_FILE" >&2; exit 1; }

CONSORT="$WORKDIR/.consort"
mkdir -p "$CONSORT/tasks"
cp "$BRIEF_FILE" "$CONSORT/tasks/$TASK_ID.brief.md"
RESULT="$CONSORT/tasks/$TASK_ID.result.json"

SYS="You are sol, the implementer in the consort harness. Execute the task in the brief on stdin. Iterate until its definition of done is observed, or stop only at a blocker a human must resolve. Do not hand unfinished checks back to the orchestrator. Keep verbose output in files; your returned summary must be short. Set task_id to '$TASK_ID'. Return only a task-result object matching the provided schema."

# workspace-write: sol may create/modify files within WORKDIR but not outside it.
printf '%s' "$(cat "$BRIEF_FILE")" | codex exec \
  -m "$MODEL" \
  -s workspace-write \
  -C "$WORKDIR" \
  --skip-git-repo-check \
  --output-schema "$SCHEMA" \
  -o "$RESULT" \
  "$SYS" >/dev/null 2>&1 || true

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ ! -s "$RESULT" ]; then
  # sol produced no schema-conforming final message (error/timeout/refusal).
  printf '{"task_id":"%s","status":"blocked","summary":"no structured result from sol","artifacts":[],"blockers":["codex returned no schema-conforming output"]}\n' "$TASK_ID" > "$RESULT"
fi

printf '{"ts":"%s","event":"delegate","task_id":"%s","model":"%s","result":"%s"}\n' \
  "$TS" "$TASK_ID" "$MODEL" ".consort/tasks/$TASK_ID.result.json" >> "$CONSORT/log.jsonl"

cat "$RESULT"
