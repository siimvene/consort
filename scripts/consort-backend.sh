# consort — backend selection (sourced, not executed).
#
# Consort's implementer/reviewer ("sol") can be either of two cross-vendor
# backends, chosen at will with CONSORT_BACKEND. Both are non-Anthropic, so
# either satisfies the cross-vendor axis when the principal is Claude.
#
#   CONSORT_BACKEND=codex   (default) — OpenAI via the Codex CLI / plugin runtime.
#   CONSORT_BACKEND=gemini            — Google via the Gemini CLI / Vertex API.
#
# This file is the single entry point the caller scripts source; it forwards to
# the selected backend's implementation (codex-backend.sh / gemini-backend.sh),
# which keep their own `consort_<backend>_*` functions.
#
# Public API:
#   consort_backend        prints the resolved backend id ("codex"/"gemini");
#                          fails if the selected backend is unavailable.
#   consort_impl_model     the effective model string, for logging.
#   consort_impl_call <mode> <schema> <workdir> <sys> <out> [payload]
#                          runs one turn on the selected backend.
#   consort_impl_probe     one cheap round-trip; prints a liveness token.

_consort_backend_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" && pwd; }
. "$(_consort_backend_dir)/codex-backend.sh"
. "$(_consort_backend_dir)/gemini-backend.sh"

_consort_selected() { echo "${CONSORT_BACKEND:-codex}"; }

consort_backend() {
  case "$(_consort_selected)" in
    codex)  consort_codex_backend ;;
    gemini) consort_gemini_backend ;;
    *) echo "consort: unknown CONSORT_BACKEND '$(_consort_selected)' (expected codex|gemini)" >&2; return 1 ;;
  esac
}

consort_impl_model() {
  case "$(_consort_selected)" in
    gemini) echo "${CONSORT_GEMINI_MODEL:-gemini-3.1-pro-preview}" ;;
    *)      echo "${CONSORT_IMPL_MODEL:-gpt-5.6-sol}" ;;
  esac
}

consort_impl_call() {
  case "$(_consort_selected)" in
    gemini) consort_gemini_call "$@" ;;
    codex)  consort_codex_call "$@" ;;
    *) echo "consort: unknown CONSORT_BACKEND '$(_consort_selected)' (expected codex|gemini)" >&2; return 1 ;;
  esac
}

consort_impl_probe() {
  case "$(_consort_selected)" in
    gemini) consort_gemini_probe ;;
    # codex has no dedicated probe; a caller that needs one can `codex exec`.
    *) command -v codex >/dev/null && codex exec -m "$(consort_impl_model)" \
         "Reply with exactly: CODEX_ALIVE" 2>/dev/null | grep -o 'CODEX_ALIVE' | head -1 ;;
  esac
}
