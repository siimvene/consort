#!/usr/bin/env bash
# consort-demo.sh <dir> — bootstrap a fresh scratch repo with a feature request,
# ready to drive the full consort flow against.
set -euo pipefail
DIR="${1:?target dir required}"
rm -rf "$DIR"; mkdir -p "$DIR"; cd "$DIR"
git init -q

cat > REQUEST.md <<'EOF'
# Feature request

Build `tally`: a small CLI that reads a text file and prints its counts as:

    <lines> <words> <chars> <path>

Flags (mutually exclusive; when given, print only that number):
  -l  lines only
  -w  words only
  -c  chars only

Ship a `test.sh` that creates a sample file and asserts the outputs for the
default form and each flag. No external dependencies.
EOF

git -c user.email=consort@local -c user.name=consort add REQUEST.md >/dev/null
git -c user.email=consort@local -c user.name=consort commit -qm "seed: feature request"
echo "$DIR"
