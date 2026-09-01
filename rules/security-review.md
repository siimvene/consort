# Security review (built-in review methodology)

Security defects come from three disjoint populations, and each detection tier
sees mostly its own: deterministic scanners catch known CVEs, leaked secrets,
and misconfigured infrastructure; rule-based static analysis catches sensitive
API misuse; model review catches logic — authorization, trust boundaries,
injection paths a rule cannot pattern-match. In side-by-side comparisons the
scanner tier and the model tier found essentially zero overlapping findings.
Run both; neither substitutes for the other.

## 1. The scanner tier runs first

The principal runs `scripts/consort-scan.sh <workdir>` (Trivy and, when a
server is configured, SonarQube — whatever is actually installed; the script
reports what it skipped). Scanner findings arrive in the shared findings shape
and merge alongside model findings. A read-only cross-reviewer cannot run
scanners; it states that and defers to the principal's scan.

Scanner output is deterministic evidence, not a lead to re-derive — but
severity is entitlement, not verdict. The model tier's job on each scanner
finding is the *reachability* call: is the vulnerable function actually
invoked, is the flagged config deployed, is the matched secret live or a
fixture? Record the verdict per finding; never silently drop one.

Findings on lines the diff never touched are pre-existing debt: report them in
a separate section, gate the change only on what it introduced or worsened.
Two exceptions always gate regardless of diff scope: a live leaked credential,
and a critical vulnerability in a dependency the diff adds or bumps.

## 2. The model tier reviews what scanners cannot see

On every diff, check the classes no pattern-matcher catches:

- **Authorization, not just authentication.** For each changed endpoint,
  query, or handler: who else can reach it, and is the object it touches
  scoped to the caller (tenant, owner, role)? Missing scoping on an ID the
  caller supplies is the classic escape.
- **Injection at construction sites.** Wherever the diff builds a command,
  query, path, URL, or markup from input, trace the input to its origin. A
  parameterized call is a fix; an escape function is a finding waiting for an
  encoding mismatch.
- **Trust-boundary shifts.** Did the diff move validation, move a check
  earlier or later, or start trusting a new source (header, env var, file,
  peer service)? Name the boundary and what now crosses it unchecked.
- **Secrets in motion.** New logging, error messages, or telemetry near
  credentials or tokens; secrets in URLs; secrets written to disk or history.
- **Dangerous sinks.** Deserialization of external data, dynamic evaluation,
  reflection, template rendering with user data, archive extraction, redirect
  and fetch targets an attacker can steer (SSRF).
- **Supply chain.** Each dependency the diff adds or bumps: pinned exact
  version, lifecycle scripts it runs, and its release age — a version
  published within the last 30 days needs an explicit justification.

## 3. Stating security findings

Finding-discipline rules apply unchanged: name the trigger (who sends what to
where, and what they get). "Uses MD5" is a style comment until the finding
says what an attacker gains. Grade by blast surface actually reachable, and
say which tier produced the finding (scanner name, or model) in the title so
divergence between tiers stays visible across rounds.
