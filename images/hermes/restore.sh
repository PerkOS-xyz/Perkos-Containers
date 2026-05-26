#!/usr/bin/env bash
# images/hermes/restore.sh
#
# Counterpart to snapshot.sh: on container start, check for a stashed
# snapshot in S3 and untar it into $HERMES_HOME BEFORE Hermes starts.
#
# Called by perkos-entrypoint.sh after the config render but before
# delegating to upstream's entrypoint (so Hermes sees the restored
# state on its first read).
#
# Inputs (env):
#   PERKOS_HIBERNATION_S3_URI  — same prefix used by snapshot.sh
#   HERMES_HOME                — target dir (default /opt/data)
#
# Behaviour:
#   - No-op + exit 0 if PERKOS_HIBERNATION_S3_URI is unset.
#   - No-op + exit 0 if state.tar.gz doesn't exist (first-ever start
#     of a freshly-launched agent — there's nothing to restore yet).
#   - Otherwise: download → untar over HERMES_HOME → echo JSON status.
#
# Exit codes:
#   0  ok (including no-op)
#   1  download or untar failure
set -euo pipefail

log() { printf '[restore] %s\n' "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }

S3_URI="${PERKOS_HIBERNATION_S3_URI:-}"
DEST="${HERMES_HOME:-/opt/data}"

if [[ -z "$S3_URI" ]]; then
  log "PERKOS_HIBERNATION_S3_URI unset — skipping restore (no-op)"
  echo '{"ok": true, "skipped": true, "reason": "no S3 URI"}'
  exit 0
fi

case "$S3_URI" in
  */) ;;
  *) S3_URI="${S3_URI}/" ;;
esac

LATEST="${S3_URI}state.tar.gz"

# Probe — does the latest snapshot exist? `aws s3 ls` exits non-zero
# on missing key; we use --output text to keep parse-friendly behaviour.
if ! aws s3 ls "$LATEST" >/dev/null 2>&1; then
  log "no snapshot found at $LATEST — fresh start"
  echo '{"ok": true, "skipped": true, "reason": "no snapshot"}'
  exit 0
fi

mkdir -p "$DEST"
TMP_TAR="/tmp/perkos-restore-$$.tar.gz"

log "downloading $LATEST → $TMP_TAR"
if ! aws s3 cp "$LATEST" "$TMP_TAR" >&2; then
  fail "download failed: $LATEST"
fi

SIZE="$(stat -c '%s' "$TMP_TAR" 2>/dev/null || stat -f '%z' "$TMP_TAR")"
log "extracting ${SIZE} bytes into $DEST"

# Untar into HERMES_HOME. We do NOT pass --overwrite because tar's
# default IS overwrite-existing-files, which is what we want — the
# snapshot is the authoritative state. Use -p to preserve perms so
# any private key / token files keep their original mode.
if ! tar -xzpf "$TMP_TAR" -C "$DEST" 2>&1 >&2; then
  fail "untar failed"
fi

rm -f "$TMP_TAR" 2>/dev/null || true

log "restore complete ($SIZE bytes)"
printf '{"ok": true, "key": "state.tar.gz", "bytes": %s, "uri": "%s"}\n' \
  "$SIZE" "$LATEST"
