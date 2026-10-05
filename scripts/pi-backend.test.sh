#!/usr/bin/env bash
# bash scripts/pi-backend.test.sh — pins how pi-backend.sh reads a model's final
# message into a findings result: a severity outside the schema enum is mapped
# (synonyms) or raised to high for adjudication instead of discarding the whole
# review, while every other schema violation still fails the leg.
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

exit "$fail"
