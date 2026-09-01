#!/usr/bin/env bash
# consort: model-free security scan — the deterministic third voice.
#
# Runs whichever supported scanners are actually present and configured
# (Trivy always when on PATH; SonarQube only when a server is reachable),
# converts their native output into the shared findings shape, and emits one
# merged {"findings":[...]} JSON object (schemas/findings.schema.json) to
# stdout. Skips are loud on stderr, never silent; a missing scanner is a
# degraded scan, not an error.
#
# Rule-based scanners and model reviewers find largely disjoint defect sets,
# so scanner findings are merged alongside the cross-model duet, not instead
# of it.
#
# Usage:
#   consort-scan.sh [workdir]        # default: current directory
#
# Env:
#   SONAR_HOST_URL   SonarQube server (default http://localhost:9000)
#   SONAR_TOKEN      SonarQube auth token; Sonar leg is skipped without it
#   CONSORT_SCAN_SKIP  comma-separated scanners to skip (trivy,sonar)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${1:-$PWD}"
cd "$WORKDIR" || { echo "consort-scan: no workdir $WORKDIR" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
OUTS=()
skip() { case ",${CONSORT_SCAN_SKIP:-}," in *",$1,"*) return 0;; *) return 1;; esac; }

# ---- trivy: vulns (lockfiles), secrets, IaC misconfigurations -------------
if skip trivy; then
  echo "consort-scan: trivy skipped via CONSORT_SCAN_SKIP" >&2
elif ! command -v trivy >/dev/null 2>&1; then
  echo "consort-scan: trivy not on PATH — vuln/secret/misconfig scan SKIPPED" >&2
else
  if trivy fs --scanners vuln,secret,misconfig --skip-dirs node_modules \
      --format json --quiet --output "$TMP/trivy.json" . 2>"$TMP/trivy.err" \
     && node "$ROOT/scripts/scan-to-findings.mjs" trivy "$TMP/trivy.json" > "$TMP/trivy.findings.json"; then
    OUTS+=("$TMP/trivy.findings.json")
  else
    echo "consort-scan: trivy FAILED (findings MISSING, do not treat this scan as clean):" >&2
    tail -n 3 "$TMP/trivy.err" >&2 || true
  fi
fi

# ---- sonar: static analysis via a SonarQube server -------------------------
# All preconditions must hold; each miss is reported so a half-configured
# setup never silently passes as "scanned".
SONAR_HOST="${SONAR_HOST_URL:-http://localhost:9000}"
if skip sonar; then
  echo "consort-scan: sonar skipped via CONSORT_SCAN_SKIP" >&2
elif ! command -v sonar-scanner >/dev/null 2>&1; then
  echo "consort-scan: sonar-scanner not on PATH — Sonar leg SKIPPED" >&2
elif [ ! -f sonar-project.properties ]; then
  echo "consort-scan: no sonar-project.properties in $WORKDIR — Sonar leg SKIPPED" >&2
elif [ -z "${SONAR_TOKEN:-}" ]; then
  echo "consort-scan: SONAR_TOKEN not set — Sonar leg SKIPPED" >&2
elif ! curl -sf -m 5 "$SONAR_HOST/api/system/status" 2>/dev/null | grep -q '"status":"UP"'; then
  echo "consort-scan: no SonarQube server UP at $SONAR_HOST — Sonar leg SKIPPED" >&2
else
  # Keep the token out of child-process argv: sonar-scanner reads SONAR_TOKEN
  # from the environment, and curl takes credentials via --config on stdin.
  export SONAR_TOKEN
  scurl() { printf 'user = "%s:"\n' "$SONAR_TOKEN" | curl -sf -m 30 --config - "$@"; }
  # sonar.working.directory keeps the scanner's .scannerwork droppings out of
  # the scanned repo (and out of reach of a repo-committed override);
  # report-task.txt lands there too.
  if sonar-scanner -Dsonar.host.url="$SONAR_HOST" \
       -Dsonar.working.directory="$TMP/scannerwork" >"$TMP/sonar.log" 2>&1; then
    TASK_FILE="$TMP/scannerwork/report-task.txt"
    CE_URL="$(grep '^ceTaskUrl=' "$TASK_FILE" 2>/dev/null | cut -d= -f2- || true)"
    PROJECT_KEY="$(grep '^projectKey=' "$TASK_FILE" 2>/dev/null | cut -d= -f2- || true)"
    # Only ever poll the server we were pointed at; a task URL on any other
    # host would leak the token to it.
    case "$CE_URL" in
      "$SONAR_HOST"/*) ;;
      *) echo "consort-scan: ceTaskUrl '$CE_URL' is not under $SONAR_HOST — refusing to poll it" >&2; CE_URL="";;
    esac
    # Analysis is processed server-side after upload; poll the compute task.
    STATUS=PENDING
    if [ -n "$CE_URL" ]; then
      for _ in $(seq 1 30); do
        STATUS="$(scurl "$CE_URL" 2>/dev/null \
          | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{console.log(JSON.parse(d).task.status)}catch{console.log("UNKNOWN")}})')" \
          || STATUS=UNKNOWN
        case "$STATUS" in SUCCESS|FAILED|CANCELED) break;; esac
        sleep 2
      done
    fi
    if [ "$STATUS" = "SUCCESS" ] && [ -n "$PROJECT_KEY" ]; then
      # A failed fetch is a failed leg, never an empty-but-"clean" result.
      if scurl "$SONAR_HOST/api/issues/search?componentKeys=$PROJECT_KEY&resolved=false&ps=500" \
           > "$TMP/sonar-issues.json"; then
        if ! scurl "$SONAR_HOST/api/hotspots/search?projectKey=$PROJECT_KEY&status=TO_REVIEW&ps=500" \
             > "$TMP/sonar-hotspots.json"; then
          echo "consort-scan: Sonar hotspot fetch FAILED — hotspot findings MISSING (issues still included)" >&2
          echo '{"hotspots":[]}' > "$TMP/sonar-hotspots.json"
        fi
        if node "$ROOT/scripts/scan-to-findings.mjs" sonar "$TMP/sonar-issues.json" "$TMP/sonar-hotspots.json" "$PROJECT_KEY" \
             > "$TMP/sonar.findings.json"; then
          OUTS+=("$TMP/sonar.findings.json")
        else
          echo "consort-scan: Sonar output conversion FAILED — Sonar findings MISSING" >&2
        fi
      else
        echo "consort-scan: Sonar issue fetch FAILED — Sonar findings MISSING, do not treat this scan as clean" >&2
      fi
    else
      echo "consort-scan: Sonar analysis did not complete (task status: $STATUS) — Sonar findings MISSING" >&2
    fi
  else
    echo "consort-scan: sonar-scanner FAILED — Sonar findings MISSING:" >&2
    tail -n 3 "$TMP/sonar.log" >&2 || true
  fi
fi

# ---- merge all scanner findings into one schema-shaped object --------------
if [ "${#OUTS[@]}" -eq 0 ]; then
  echo "consort-scan: NO scanner produced findings — this scan verified nothing" >&2
  echo '{"findings":[]}'
else
  node -e '
    const fs = require("node:fs");
    const findings = process.argv.slice(1).flatMap((p) => {
      try { return JSON.parse(fs.readFileSync(p, "utf8")).findings ?? []; }
      catch { return []; }
    });
    console.log(JSON.stringify({ findings }, null, 1));
  ' "${OUTS[@]}"
fi
