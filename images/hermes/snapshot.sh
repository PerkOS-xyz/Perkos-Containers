#!/usr/bin/env bash
# images/hermes/snapshot.sh
#
# Tars $HERMES_HOME and uploads to S3 so a hibernated agent can be
# restored when scaled back to 1. Runs in two places:
#
#   1. From perkos-entrypoint.sh's SIGTERM trap, AFTER upstream Hermes
#      has been told to stop and has finished its own shutdown. This
#      gives us a clean snapshot — no half-written conversation files.
#
#   2. (Future) Manually via `docker exec` for ad-hoc backups.
#
# Inputs (env):
#   PERKOS_HIBERNATION_S3_URI  — full target prefix, e.g.
#                                 s3://perkos-agent-snapshots-prod/0xabc/MyBot/
#                                 (the trailing slash is part of the
#                                 convention — keys land UNDER it)
#   HERMES_HOME                — source dir (default /opt/data)
#   PERKOS_HIBERNATION_KMS_KEY — optional override; the bucket already
#                                 has a default KMS key so we usually
#                                 leave this unset.
#
# Behaviour:
#   - No-op + exit 0 if PERKOS_HIBERNATION_S3_URI is unset or empty.
#     Keeps the script safe in dev / smoke / unconfigured environments.
#   - Writes two objects: state.tar.gz (latest) and
#     state-<UTC ISO>.tar.gz (history; the bucket lifecycle policy
#     expires non-current after 30d).
#   - Echoes one JSON line to stdout on success so the bridge can
#     parse + report back to the miniapp:
#       { "ok": true, "key": "state.tar.gz", "bytes": 12345 }
#
# Exit codes:
#   0  ok (including no-op)
#   1  upload failure
#   2  tar failure
set -euo pipefail

log() { printf '[snapshot] %s\n' "$*" >&2; }
fail() { log "ERROR: $*"; exit "${2:-1}"; }

S3_URI="${PERKOS_HIBERNATION_S3_URI:-}"
SRC="${HERMES_HOME:-/opt/data}"

if [[ -z "$S3_URI" ]]; then
  log "PERKOS_HIBERNATION_S3_URI unset — skipping (no-op)"
  echo '{"ok": true, "skipped": true, "reason": "no S3 URI"}'
  exit 0
fi

# Normalise: ensure trailing slash so we can append a basename safely.
case "$S3_URI" in
  */) ;;
  *) S3_URI="${S3_URI}/" ;;
esac

if [[ ! -d "$SRC" ]]; then
  log "source dir $SRC does not exist — nothing to snapshot"
  echo '{"ok": true, "skipped": true, "reason": "source missing"}'
  exit 0
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
TMP_TAR="/tmp/perkos-snapshot-${TS}.tar.gz"

log "tarring $SRC → $TMP_TAR"
# --exclude socket files & pid files; Hermes recreates these on start.
if ! tar -czf "$TMP_TAR" \
    --exclude='*.sock' \
    --exclude='*.pid' \
    --exclude='tmp/*' \
    -C "$SRC" . 2>&1; then
  fail "tar failed" 2
fi

SIZE="$(stat -c '%s' "$TMP_TAR" 2>/dev/null || stat -f '%z' "$TMP_TAR")"
log "tar OK ($SIZE bytes); uploading to ${S3_URI}state.tar.gz + ${S3_URI}state-${TS}.tar.gz"

# Build the SSE flag set. The bucket already has a default KMS key on
# it, so the encryption happens regardless — but specifying
# --sse aws:kms makes the intent explicit and lets a caller override
# the key id if PERKOS_HIBERNATION_KMS_KEY is set.
SSE_ARGS=( --sse aws:kms )
if [[ -n "${PERKOS_HIBERNATION_KMS_KEY:-}" ]]; then
  SSE_ARGS+=( --sse-kms-key-id "$PERKOS_HIBERNATION_KMS_KEY" )
fi

# Use cp twice rather than a copy: each is ~1 short HTTP roundtrip
# for the small tarballs we expect, and it avoids the cross-key copy
# tax. If the latest write fails, we still want the timestamped one
# to land so the user has SOMETHING to restore from.
TS_KEY="${S3_URI}state-${TS}.tar.gz"
LATEST_KEY="${S3_URI}state.tar.gz"

if ! aws s3 cp "$TMP_TAR" "$TS_KEY" "${SSE_ARGS[@]}" >&2; then
  fail "upload of timestamped snapshot failed: $TS_KEY"
fi
if ! aws s3 cp "$TMP_TAR" "$LATEST_KEY" "${SSE_ARGS[@]}" >&2; then
  fail "upload of latest snapshot failed: $LATEST_KEY"
fi

rm -f "$TMP_TAR" 2>/dev/null || true

log "snapshot complete ($SIZE bytes)"
printf '{"ok": true, "key": "state.tar.gz", "timestampedKey": "state-%s.tar.gz", "bytes": %s, "uri": "%s"}\n' \
  "$TS" "$SIZE" "$LATEST_KEY"
