#!/usr/bin/env bash
# bash scripts/codex-backend.test.sh — pins the Codex account failover in
# codex-backend.sh against a stub `codex` on PATH: home resolution (~/,
# @default, @termscape, missing logins, duplicates), failover only on a
# usage/rate limit read from codex's error events (never the transcript),
# the workspace-write "untouched tree" rule, transport selection, and the
# unchanged single-call path when CONSORT_CODEX_HOMES is unset.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME/.codex" "$T/bin"
unset CODEX_HOME CONSORT_CODEX_HOMES CONSORT_CODEX_BACKEND CONSORT_TERMSCAPE_DATA_DIR NODETERM_CX_ROOT
: > "$HOME/.codex/auth.json"; echo ok > "$HOME/.codex/behave"

cat > "$T/bin/codex" <<'STUB'
#!/usr/bin/env bash
# stub codex: behaviour from $CODEX_HOME/behave; logs every exec it serves.
[ "${1:-}" = exec ] || exit 2
case " $* " in *" --help "*) echo "  --ignore-user-config"; exit 0 ;; esac
home="${CODEX_HOME:-$HOME/.codex}"
out=""; wd=""; prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"; [ "$prev" = "-C" ] && wd="$a"; prev="$a"
done
echo "${CODEX_HOME:-<inherited>}" >> "$STUB_LOG"
cat > "$home/stdin.seen"
case "$(cat "$home/behave")" in
  ok)             echo '{"type":"turn.completed"}'; printf '{"findings":[{"title":"from %s"}]}' "$(basename "$home")" > "$out" ;;
  alive)          printf 'CODEX_ALIVE' > "$out" ;;
  limit)          echo '{"type":"error","message":"You'"'"'ve hit your usage limit. Upgrade to Pro or try again at 5:00 PM."}'
                  echo '{"type":"turn.failed","error":{"message":"usage_limit_reached"}}'; exit 1 ;;
  limit-stderr)   echo "ERROR: Usage limit reached" >&2; exit 1 ;;
  ratelimit-429)  echo '{"type":"turn.failed","error":{"message":"{\"status\":429,\"error\":{\"type\":\"rate_limit_exceeded\"}}"}}'; exit 1 ;;
  fail)           echo '{"type":"turn.failed","error":{"message":"invalid_request_error: bad schema"}}'; exit 1 ;;
  fail-transcript) echo '{"type":"item.completed","item":{"type":"agent_message","text":"this code greps for usage limit and rate limit strings"}}'
                  echo '{"type":"turn.failed","error":{"message":"stream disconnected"}}'; exit 1 ;;
  limit-edit)     echo half > "$wd/half-applied.txt"
                  echo '{"type":"turn.failed","error":{"message":"usage limit"}}'; exit 1 ;;
esac
STUB
chmod +x "$T/bin/codex"
export PATH="$T/bin:$PATH" STUB_LOG="$T/log"
. "$HERE/codex-backend.sh"

fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1${2:+ — $2}"; fails=$((fails+1)); }
check() { if eval "$2"; then ok "$1"; else fail "$1" "${3:-}"; fi; }
mkhome() { mkdir -p "$T/$1"; : > "$T/$1/auth.json"; echo "$2" > "$T/$1/behave"; }
SCHEMA="$T/schema.json"; echo '{}' > "$SCHEMA"
PAYLOAD="$T/payload"; echo "the diff" > "$PAYLOAD"
call() { # call <mode> [workdir] -> OUT, ERR, LOG
  : > "$STUB_LOG"; OUT="$T/out"; ERR="$T/err"; rm -f "$OUT"
  consort_codex_call "$1" "$SCHEMA" "${2:-$T}" "review" "$OUT" "$PAYLOAD" 2>"$ERR"
}

# 1. unset: one call on the inherited home, payload on stdin, --json passed
CONSORT_CODEX_BACKEND=exec call read-only
check "unset: single call on inherited CODEX_HOME" '[ "$(cat "$STUB_LOG")" = "<inherited>" ]' "$(cat "$STUB_LOG")"
check "unset: result written" 'grep -q "from .codex" "$OUT"'
check "unset: payload arrives on stdin" '[ "$(cat "$HOME/.codex/stdin.seen")" = "the diff" ]'
check "unset: no account lines on stderr" '! grep -q "codex account" "$ERR"' "$(cat "$ERR")"

# 2. A limited -> B runs; evidence names both
mkhome a limit; mkhome b ok
CONSORT_CODEX_HOMES="$T/a:$T/b" call read-only
check "failover: A then B tried" '[ "$(tr "\n" " " < "$STUB_LOG")" = "$T/a $T/b " ]' "$(cat "$STUB_LOG")"
check "failover: B result kept" 'grep -q "from b" "$OUT"'
check "failover: A reported at limit" 'grep -q "account 1/2 is at its usage limit" "$ERR"'
check "failover: B reported as the runner" 'grep -q "account 2/2 ran the call" "$ERR"'
check "failover: payload reached B too" '[ "$(cat "$T/b/stdin.seen")" = "the diff" ]'

# 3. limit via stderr and via a 429 API error also fail over
mkhome s limit-stderr; mkhome r ratelimit-429
CONSORT_CODEX_HOMES="$T/s:$T/r:$T/b" call read-only
check "stderr limit + 429 both fail over" '[ "$(grep -c . "$STUB_LOG")" -eq 3 ] && grep -q "from b" "$OUT"' "$(cat "$ERR")"

# 4. a non-limit failure stops the walk
mkhome f fail
CONSORT_CODEX_HOMES="$T/f:$T/b" call read-only
check "non-limit failure: B never called" '[ "$(cat "$STUB_LOG")" = "$T/f" ]' "$(cat "$STUB_LOG")"
check "non-limit failure: out empty" '[ ! -s "$OUT" ]'
check "non-limit failure: says why + error line" 'grep -q "failed without a usage limit" "$ERR" && grep -q "bad schema" "$ERR"'

# 5. test the test: limit words in the TRANSCRIPT must not trigger failover
mkhome x fail-transcript
CONSORT_CODEX_HOMES="$T/x:$T/b" call read-only
check "transcript mention is not a limit" '[ "$(cat "$STUB_LOG")" = "$T/x" ]' "$(cat "$ERR")"

# 6. all limited
mkhome c limit
CONSORT_CODEX_HOMES="$T/a:$T/c" call read-only
check "all limited: both tried, out empty" '[ "$(grep -c . "$STUB_LOG")" -eq 2 ] && [ ! -s "$OUT" ]'
check "all limited: says so" 'grep -q "every Codex account in CONSORT_CODEX_HOMES is at its usage limit (2 tried)" "$ERR"'

# 7. resolution: ~/, @default, missing login skipped, duplicates once
mkdir -p "$T/nologin"; mkdir -p "$HOME/acct"; : > "$HOME/acct/auth.json"; echo ok > "$HOME/acct/behave"
echo limit > "$HOME/.codex/behave"
CONSORT_CODEX_HOMES="$T/nologin:@default:~/acct:$HOME/.codex" call read-only
check "resolution: @default then ~/acct, dup + nologin skipped" '[ "$(tr "\n" " " < "$STUB_LOG")" = "$HOME/.codex $HOME/acct " ]' "$(cat "$STUB_LOG")"
check "resolution: missing login reported" 'grep -q "skipping Codex home without a login" "$ERR"'
CONSORT_CODEX_HOMES="$T/nologin" call read-only
check "no usable home: nothing ran, said so" '[ ! -s "$STUB_LOG" ] && grep -q "names no Codex home with a login" "$ERR"'
CONSORT_CODEX_HOMES="@bogus:$T/b" call read-only
check "unknown token warned, rest used" 'grep -q "unknown token .@bogus." "$ERR" && grep -q "from b" "$OUT"'
echo ok > "$HOME/.codex/behave"

# 8. @termscape: system account, then managed homes at sha256(userData\0id)[:16]
TS="$T/ts data"; mkdir -p "$TS"
cat > "$TS/settings.json" <<'JSON'
{"codexAccounts":[{"id":"acct-1"},{"id":"half","pending":true},{"id":"../evil"},{"id":"acct-2"}]}
JSON
digest() { printf '%s\0%s' "$TS" "$1" | shasum -a 256 | cut -c1-16; }
H1="$T/cx/$(digest acct-1)"; H2="$T/cx/$(digest acct-2)"
mkdir -p "$H1" "$H2"; : > "$H1/auth.json"; : > "$H2/auth.json"; echo limit > "$H1/behave"; echo ok > "$H2/behave"
echo limit > "$HOME/.codex/behave"
CONSORT_TERMSCAPE_DATA_DIR="$TS" NODETERM_CX_ROOT="$T/cx" CONSORT_CODEX_HOMES=@termscape call read-only
check "@termscape: system, acct-1, acct-2 in order" '[ "$(tr "\n" " " < "$STUB_LOG")" = "$HOME/.codex $H1 $H2 " ]' "$(cat "$STUB_LOG") $(cat "$ERR")"
check "@termscape: pending and malformed ids skipped" '[ "$(grep -c . "$STUB_LOG")" -eq 3 ]'
check "@termscape: landed on acct-2" 'grep -q "account 3/3 ran the call" "$ERR"'
CONSORT_TERMSCAPE_DATA_DIR="$T/none" CONSORT_CODEX_HOMES=@termscape call read-only
check "@termscape without Termscape: system account only, warned" '[ "$(cat "$STUB_LOG")" = "$HOME/.codex" ] && grep -q "no Termscape settings" "$ERR"'
echo ok > "$HOME/.codex/behave"

# 9. workspace-write: fail over only when the limited attempt left the tree untouched
WD="$T/wd"; mkdir -p "$WD"; git -C "$WD" init -q; echo x > "$WD/f"; git -C "$WD" add f
git -C "$WD" -c user.email=t@t -c user.name=t commit -qm init
CONSORT_CODEX_HOMES="$T/a:$T/b" call workspace-write "$WD"
check "write, untouched tree: fails over" 'grep -q "from b" "$OUT"' "$(cat "$ERR")"
mkhome e limit-edit
CONSORT_CODEX_HOMES="$T/e:$T/b" call workspace-write "$WD"
check "write, edited tree: stops, B never called" '[ "$(cat "$STUB_LOG")" = "$T/e" ] && [ ! -s "$OUT" ]' "$(cat "$STUB_LOG")"
check "write, edited tree: says why" 'grep -q "not failing over a workspace-write call" "$ERR"'
rm -f "$WD/half-applied.txt"
NG="$T/nogit"; mkdir -p "$NG"
CONSORT_CODEX_HOMES="$T/a:$T/b" call workspace-write "$NG"
check "write outside git: no failover" '[ "$(cat "$STUB_LOG")" = "$T/a" ]' "$(cat "$STUB_LOG")"

# 10. transport: a home list forces exec; explicit plugin + homes is refused
mkdir -p "$HOME/.claude/plugins/cache/m/codex/1.0.0/scripts"; : > "$HOME/.claude/plugins/cache/m/codex/1.0.0/scripts/codex-companion.mjs"
check "auto without homes picks plugin" '[ "$(consort_codex_backend 2>/dev/null)" = plugin ] || ! command -v node >/dev/null'
check "auto with homes picks exec" '[ "$(CONSORT_CODEX_HOMES=$T/b consort_codex_backend)" = exec ]'
check "plugin + homes refused" '! CONSORT_CODEX_BACKEND=plugin CONSORT_CODEX_HOMES=$T/b consort_codex_backend 2>/dev/null'

# 11. probe walks the accounts
mkhome p alive
check "probe: limited A, alive B" '[ "$(CONSORT_CODEX_HOMES=$T/a:$T/p consort_codex_probe 2>/dev/null)" = CODEX_ALIVE ]'
check "probe: all limited prints nothing" '[ -z "$(CONSORT_CODEX_HOMES=$T/a:$T/c consort_codex_probe 2>/dev/null)" ]'

echo; [ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
