#!/usr/bin/env bash
# Register a freshly-built runtime image with PerkOS-API.
#
# POSTs to /internal/runtimes/ingest (API-key auth). The API creates the
# /runtime_images/{runtime:primaryTag} doc on the BETA channel with the
# resolved upstream + build status, and a pending behavior test. Promotion
# to the public channel is a separate admin action once the behavior test
# passes.
#
# Required env:
#   PERKOS_API_URL      base URL, e.g. https://api.perkos.xyz
#   RUNTIME_INGEST_KEY  shared secret matching the API's env of the same name
#
# Usage:
#   ingest-runtime-image.sh \
#     --runtime openclaw --primary-tag <tag> \
#     --upstream-source <repo> --upstream-version <ver-or-empty> \
#     --upstream-digest sha256:... --a2a-version 0.12.0 --build-status ok
set -euo pipefail

RUNTIME="" PRIMARY_TAG="" SRC="" VERSION="" DIGEST="" A2A="" BUILD_STATUS="ok"
while [ $# -gt 0 ]; do
  case "$1" in
    --runtime) RUNTIME="$2"; shift 2;;
    --primary-tag) PRIMARY_TAG="$2"; shift 2;;
    --upstream-source) SRC="$2"; shift 2;;
    --upstream-version) VERSION="$2"; shift 2;;
    --upstream-digest) DIGEST="$2"; shift 2;;
    --a2a-version) A2A="$2"; shift 2;;
    --build-status) BUILD_STATUS="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

: "${PERKOS_API_URL:?PERKOS_API_URL is required}"
: "${RUNTIME_INGEST_KEY:?RUNTIME_INGEST_KEY is required}"
for v in RUNTIME PRIMARY_TAG SRC DIGEST A2A; do
  if [ -z "${!v}" ]; then echo "missing --${v,,}" >&2; exit 2; fi
done

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# null when upstream ships no semver label; JSON-encode otherwise.
if [ -z "$VERSION" ]; then VERSION_JSON="null"; else VERSION_JSON="\"${VERSION}\""; fi

BODY="$(cat <<JSON
{
  "runtime": "${RUNTIME}",
  "primaryTag": "${PRIMARY_TAG}",
  "upstream": {
    "source": "${SRC}",
    "version": ${VERSION_JSON},
    "digest": "${DIGEST}",
    "resolvedAt": "${NOW}"
  },
  "a2aVersion": "${A2A}",
  "build": { "status": "${BUILD_STATUS}", "runId": "${GITHUB_RUN_ID:-}", "finishedAt": "${NOW}" }
}
JSON
)"

echo "Registering ${RUNTIME}:${PRIMARY_TAG} (beta) at ${PERKOS_API_URL}/internal/runtimes/ingest"
HTTP="$(curl -sS -o /tmp/ingest-resp.json -w '%{http_code}' \
  -X POST "${PERKOS_API_URL}/internal/runtimes/ingest" \
  -H "content-type: application/json" \
  -H "x-runtime-ingest-key: ${RUNTIME_INGEST_KEY}" \
  --data "${BODY}")"

if [ "$HTTP" != "200" ]; then
  echo "ingest failed (HTTP ${HTTP}):" >&2
  cat /tmp/ingest-resp.json >&2 || true
  exit 1
fi
echo "ok"
