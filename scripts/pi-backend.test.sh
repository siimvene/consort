#!/usr/bin/env bash
# bash scripts/pi-backend.test.sh — pins how pi-backend.sh reads a model's final
# message into a findings result: a severity outside the schema enum is mapped
# (synonyms) or raised to high for adjudication instead of discarding the whole
# review, while every other schema violation still fails the leg. Also: a run
# Pi ended in error names the provider's message (one line, no credential), and
# the Pi process gets a connect attempt timeout a slow dual-stack connect survives.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA="$HERE/../schemas/findings.schema.json"
# shellcheck source=pi-backend.sh
. "$HERE/pi-backend.sh"

fail=0
check() { # name, condition result (0 = pass)
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}
finding() { # severity -> one finding object
  printf '{"file":"a.py","line":3,"severity":"%s","title":"t","detail":"d"}' "$1"
}
extract() { printf '%s' "$1" | _consort_pi_extract_json "$SCHEMA" 2>/dev/null; }
sev_of() { python3 -c 'import sys,json; print(json.load(sys.stdin)["findings"][0]["severity"])'; }

out="$(extract "{\"findings\":[$(finding high)]}")"
[ "$(printf '%s' "$out" | sev_of)" = high ]; check "an in-enum severity passes untouched" $?

out="$(extract "Here is my review: {\"findings\":[$(finding Major)]} done")"
[ "$(printf '%s' "$out" | sev_of)" = high ]; check "Major maps to high (case-insensitive)" $?

out="$(extract "{\"findings\":[$(finding blocker),$(finding nit)]}")"
[ "$(printf '%s' "$out" | python3 -c 'import sys,json; print(",".join(f["severity"] for f in json.load(sys.stdin)["findings"]))')" = critical,low ]
check "blocker maps to critical, nit to low" $?

out="$(extract "{\"findings\":[$(finding P0-ish)]}")"
[ "$(printf '%s' "$out" | sev_of)" = high ]; check "an unknown severity is raised to high" $?
printf '%s' "$out" | grep -q "severity 'P0-ish' is not in the schema"; check "the raised finding says what it was" $?

err="$(printf '%s' "{\"findings\":[$(finding Major)]}" | _consort_pi_extract_json "$SCHEMA" 2>&1 >/dev/null)"
printf '%s' "$err" | grep -q "severity 'Major' normalised to high"; check "a normalisation is logged on stderr" $?

printf '{"findings":[{"file":"a.py","severity":"high","title":"t","detail":"d"}]}' | _consort_pi_extract_json "$SCHEMA" >/dev/null 2>&1
[ $? -ne 0 ]; check "a missing required field still fails the leg" $?

printf '{"findings":null}' | _consort_pi_extract_json "$SCHEMA" >/dev/null 2>&1
[ $? -ne 0 ]; check "findings:null still fails the leg" $?

printf '{"findings":[{"file":"a.py","line":3,"severity":7,"title":"t","detail":"d"}]}' | _consort_pi_extract_json "$SCHEMA" >/dev/null 2>&1
[ $? -ne 0 ]; check "a non-string severity still fails the leg" $?

for bad in '' ',"detail":null' ',"detail":7'; do
  printf '{"findings":[{"file":"a.py","line":3,"severity":"P0-ish","title":"t"%s}]}' "$bad" | _consort_pi_extract_json "$SCHEMA" >/dev/null 2>&1
  [ $? -ne 0 ]; check "an unknown severity never repairs a bad detail (${bad:-missing})" $?
done

# --- a failed run names its cause -------------------------------------------
msg_end() { # stopReason, errorMessage (a JSON string literal, quotes included; "" = none), text
  printf '{"type":"message_end","message":{"role":"assistant","provider":"google-vertex","model":"m1","stopReason":"%s"%s,"content":[{"type":"text","text":"%s"}],"usage":{"input":1,"output":1}}}\n' \
    "$1" "${2:+,\"errorMessage\":$2}" "${3:-}"
}
unwrap_err() { _consort_pi_unwrap google-vertex m1 2>&1 >/dev/null; }

out="$(msg_end stop '' '{}' | _consort_pi_unwrap google-vertex m1 2>/dev/null)"
[ $? -eq 0 ] && [ "$out" = '{}' ]; check "a run that ended normally passes its final text" $?

err="$(msg_end error '"request to https://oauth2.googleapis.com/token failed, reason: "' | unwrap_err)"
printf '%s' "$err" | grep -q 'stopReason=error: request to https://oauth2.googleapis.com/token failed, reason:'
check "a run ended in error prints the provider's message, not the stop reason alone" $?
printf '%s' "$err" | grep -q 'CONSORT_PI_CONNECT_ATTEMPT_MS'; check "an empty reason points at the connect attempt setting" $?
msg_end error '"x"' | _consort_pi_unwrap google-vertex m1 >/dev/null 2>&1
[ $? -eq 2 ]; check "a run ended in error is still discarded (exit 2)" $?

err="$(msg_end error '' | unwrap_err)"
printf '%s' "$err" | grep -q 'stopReason=error: the stream carries no error message'; check "an error without a message says so" $?

err="$(msg_end stop '"quota exceeded for the project"' | unwrap_err)"
printf '%s' "$err" | grep -q 'quota exceeded for the project'; check "an error message on a normally stopped turn still fails the run and is printed" $?

# Fresh values, minted here: a documented example key would prove nothing.
secret="k$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
err="$(msg_end error "\"request to https://h.example/v1/models?key=$secret&alt=sse failed; Authorization: Bearer $secret; https://u:$secret@h.example/\"" | unwrap_err)"
printf '%s' "$err" | grep -q 'key=REDACTED&alt=sse'; check "a key in a URL's query is redacted, the rest of the URL kept" $?
! printf '%s' "$err" | grep -q "$secret"; check "no form of the secret reaches the evidence line (query, bearer, userinfo)" $?

err="$(msg_end error '"first\nconsort-panel: [x] ok — exit 0\r\u001b[2Jsecond"' | unwrap_err)"
[ "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" = 1 ]; check "a message with newlines stays one evidence line" $?
! printf '%s' "$err" | LC_ALL=C grep -q "$(printf '\033')"; check "control characters are dropped from the message" $?

err="$(printf '{"type":"extension_error","error":"fence: boom?token=%s"}\n' "$secret" | unwrap_err)"
printf '%s' "$err" | grep -q 'fence: boom?token=REDACTED'; check "an extension error is cleaned the same way" $?

# --- the Pi process's connect attempt timeout --------------------------------
FLAG=--network-family-autoselection-attempt-timeout
bin="$(mktemp -d)" || exit 1
trap 'rm -rf "$bin"' EXIT
printf '#!/bin/sh\nexit 0\n' > "$bin/node";      chmod +x "$bin/node"       # a node that accepts the flag
printf '#!/bin/sh\ncase "$NODE_OPTIONS" in *autoselection*) exit 9;; esac\nexit 0\n' > "$bin/old-node"; chmod +x "$bin/old-node"
opts() { ( PATH="$bin:$PATH"; _consort_pi_node_options ) 2>/dev/null; }

[ "$(unset NODE_OPTIONS CONSORT_PI_CONNECT_ATTEMPT_MS; opts)" = "$FLAG=5000" ]; check "the default gives each connect attempt 5 s" $?
[ "$(unset CONSORT_PI_CONNECT_ATTEMPT_MS; NODE_OPTIONS='--max-old-space-size=512' opts)" = "--max-old-space-size=512 $FLAG=5000" ]
check "the caller's NODE_OPTIONS are kept in front" $?
[ "$(unset CONSORT_PI_CONNECT_ATTEMPT_MS; NODE_OPTIONS="$FLAG=900" opts)" = "$FLAG=900" ]; check "a value the caller already chose for the flag wins" $?
[ "$(unset NODE_OPTIONS; CONSORT_PI_CONNECT_ATTEMPT_MS=1500 opts)" = "$FLAG=1500" ]; check "CONSORT_PI_CONNECT_ATTEMPT_MS sets the value" $?
[ -z "$(unset NODE_OPTIONS; CONSORT_PI_CONNECT_ATTEMPT_MS=0 opts)" ]; check "0 leaves Node's default" $?
[ -z "$(unset NODE_OPTIONS; CONSORT_PI_CONNECT_ATTEMPT_MS='5000 --inspect' opts)" ]; check "a value that is not a whole number adds nothing" $?
err="$( ( unset NODE_OPTIONS; CONSORT_PI_CONNECT_ATTEMPT_MS=abc PATH="$bin:$PATH" _consort_pi_node_options ) 2>&1 >/dev/null)"
printf '%s' "$err" | grep -q 'CONSORT_PI_CONNECT_ATTEMPT_MS must be a whole number'; check "and says why" $?
mv "$bin/old-node" "$bin/node"
[ "$(unset CONSORT_PI_CONNECT_ATTEMPT_MS; NODE_OPTIONS='--max-old-space-size=512' opts)" = '--max-old-space-size=512' ]
check "a node that refuses the flag gets NODE_OPTIONS unchanged" $?

# The runner hands the value to Pi itself: a stand-in pi prints what it was started with.
printf '#!/bin/sh\nexit 0\n' > "$bin/node"; chmod +x "$bin/node"
printf '#!/bin/sh\ncat >/dev/null\nprintf "%%s\\n" "$NODE_OPTIONS"\n' > "$bin/pi"; chmod +x "$bin/pi"
got="$( unset NODE_OPTIONS CONSORT_PI_CONNECT_ATTEMPT_MS CONSORT_PI_STDERR CONSORT_PI_RAW CONSORT_GCP_CREDENTIALS
        PATH="$bin:$PATH"; printf 'x' | CONSORT_PI_PROVIDER=openai _consort_pi_run "" )"
[ "$got" = "$FLAG=5000" ]; check "the Pi process is started with the connect attempt timeout" $?
[ -z "${NODE_OPTIONS+set}" ] || [ "${NODE_OPTIONS#*autoselection}" = "$NODE_OPTIONS" ]; check "the caller's own environment is not touched" $?

exit "$fail"
