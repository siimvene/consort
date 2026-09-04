#!/usr/bin/env python3
"""consort — Gemini (Vertex AI) reviewer companion (api transport).

Read-only structured review via Vertex `generateContent`. The Google-model
counterpart to the Codex companion: the cross-vendor reviewer when the principal
is Claude. Stdlib only (urllib), so consort gains no Python deps.

Diff-only by design — no repo access. For repo-wide sweeps use the `cli`
transport (the `gemini` CLI running in the workdir); see gemini-backend.sh.

Contract (matches the backend `*_call` signature):
  stdin              the system/instructions prompt
  --schema  FILE     JSON Schema the output must conform to
  --out     FILE     where to write the schema-shaped JSON object
  --payload FILE     optional <stdin> block (the diff)
On success writes one JSON object to --out; on any failure writes nothing and
exits 0 (callers keep their empty-result fallback).

Env:
  CONSORT_GEMINI_MODEL     default gemini-3.1-pro-preview
  CONSORT_GEMINI_LOCATION  default global  (EU: gemini-2.5-pro @ europe-west4)
  CONSORT_GCP_PROJECT      default from `gcloud config get-value project`
  CONSORT_GEMINI_TOKEN     bearer token; default `gcloud auth print-access-token`
  CONSORT_GEMINI_MAXTOK    default 8192
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request


def _sh(cmd: list[str]) -> str:
    return subprocess.run(cmd, capture_output=True, text=True).stdout.strip()


def _cfg(name: str, default: str = "") -> str:
    return os.environ.get(name) or default


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--schema", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--payload", default="")
    args = ap.parse_args()

    model = _cfg("CONSORT_GEMINI_MODEL", "gemini-3.1-pro-preview")
    location = _cfg("CONSORT_GEMINI_LOCATION", "global")
    project = _cfg("CONSORT_GCP_PROJECT") or _sh(
        ["gcloud", "config", "get-value", "project"])
    token = _cfg("CONSORT_GEMINI_TOKEN") or _sh(
        ["gcloud", "auth", "print-access-token"])
    max_tok = int(_cfg("CONSORT_GEMINI_MAXTOK", "8192"))

    if not (project and token):
        print("gemini-companion: no project or token", file=sys.stderr)
        return 0

    sys_prompt = sys.stdin.read()
    schema_text = open(args.schema).read()
    payload = open(args.payload).read() if args.payload else ""

    # Schema-in-prompt (not native responseSchema): consort schemas use
    # additionalProperties:false, which Gemini's responseSchema rejects.
    # responseMimeType still forces raw JSON; the schema text pins the shape.
    prompt = (
        f"{sys_prompt}\n\n"
        + (f"<stdin>\n{payload}\n</stdin>\n\n" if payload else "")
        + "<output-contract>\nYour entire response must be exactly one JSON "
        "object conforming to this JSON Schema. No prose, no code fences.\n"
        f"{schema_text}\n</output-contract>"
    )

    host = ("https://aiplatform.googleapis.com" if location == "global"
            else f"https://{location}-aiplatform.googleapis.com")
    url = (f"{host}/v1/projects/{project}/locations/{location}"
           f"/publishers/google/models/{model}:generateContent")
    body = {
        "contents": [{"role": "user", "parts": [{"text": prompt}]}],
        "generationConfig": {"responseMimeType": "application/json",
                             "maxOutputTokens": max_tok, "temperature": 0},
    }
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {token}",
                 "x-goog-user-project": project,
                 "Content-Type": "application/json"},
        method="POST")
    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            payload_json = json.loads(resp.read())
    except (urllib.error.URLError, TimeoutError, ValueError) as e:
        print(f"gemini-companion: request failed: {e}", file=sys.stderr)
        return 0

    try:
        cand = payload_json["candidates"][0]
        text = cand["content"]["parts"][0]["text"]
        obj = json.loads(text)
    except (KeyError, IndexError, ValueError) as e:
        reason = (payload_json.get("candidates") or [{}])[0].get("finishReason", "?")
        print(f"gemini-companion: unparseable (finishReason={reason}): {e}",
              file=sys.stderr)
        return 0

    with open(args.out, "w") as f:
        json.dump(obj, f)
    return 0


if __name__ == "__main__":
    sys.exit(main())
