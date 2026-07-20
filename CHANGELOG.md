# Changelog

All notable changes to consort are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html) while
still in 0.x.

## [0.2.0] — 2026-07-20

### Changed
- **Panel drafts now come from independent spawned agents rather than the
  pipeline principal.** In 0.1.0 the principal produced one panel draft
  and sol produced the other; the same context that would later
  synthesize the panel was already committed to one of the two positions.
  0.2.0 spawns both panel voices as fresh subagent runs, keeping the
  principal purely as the synthesizer. Removes the "principal grading its
  own homework" bias in blind-panel synthesis.
  ([12ae25b](https://github.com/siimvene/consort/commit/12ae25b))

## [0.1.0] — 2026-07-18

Initial marketplace release.

### Added
- Cross-vendor development lifecycle: interview → spec → plan → implement
  → review → gate, with blind panels at spec and review.
- Slash-command surface: `/consort:run`, `/consort:review`, `/consort:plan`.
- Pluggable Codex backend — auto-detect and use the official Codex
  Claude Code plugin runtime when installed
  (`scripts/codex-backend.sh`). Falls back to raw `codex exec` CLI.
  Override via `CONSORT_CODEX_BACKEND=exec|plugin`.
  ([d3c2077](https://github.com/siimvene/consort/commit/d3c2077))
- Schema-forced findings JSON; deterministic merge script
  (`scripts/merge-findings.mjs`).
- Model-free gate (`scripts/consort-gate.sh`) — tests green, non-test
  code touched, `test.sh` at repo root.
- State bus at `.consort/` — every phase artifact resumable from disk.
