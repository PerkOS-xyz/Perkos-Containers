#!/usr/bin/env bash
# restore.sh — generic (Hermes + OpenClaw)
#
# Counterpart to snapshot.sh. On container start (called by the entrypoint
# BEFORE the runtime starts), pull the agent's encrypted snapshot from S3,
# decrypt it (KMS-unwrap the data key → openssl AES-256-CBC), and untar it over
# the state dir — so a freshly-launched container "clones" the hibernated agent.
#
# Picks the newest snapshot by default; PERKOS_RESTORE_TS restores a specific
# one (point-in-time recovery from the Settings → Backups UI).
#
# Inputs (env):
#   PERKOS_HIBERNATION_S3_URI   s3://bucket/<wallet>/<agent>/  (trailing slash)
#   PERKOS_AGENT_ID             encryption-context value (must match snapshot)
#   PERKOS_STATE_DIR            target dir; fallback HERMES_HOME / OPENCLAW_HOME / /opt/data
#   PERKOS_RESTORE_TS           optional: restore state-<TS> instead of the newest
#
# No-op (exit 0) when: no S3 URI, or no snapshot exists (first-ever launch).
# Exit codes: 0 ok/no-op · 1 download/kms/decrypt/untar fail
#
# STATUS: UNVALIDATED until tested against the real KMS key (Phase 1 infra) —
# must round-trip with snapshot.sh. See HIBERNATION-SNAPSHOT-DESIGN.md.
set -euo pipefail

log() { printf '[restore] %s\n' "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }
skip() { log "$1"; printf '{"ok":true,"skipped":true,"reason":"%s"}\n' "$2"; exit 0; }

S3_URI="${PERKOS_HIBERNATION_S3_URI:-}"
AGENT_ID="${PERKOS_AGENT_ID:-unknown}"
DEST="${PERKOS_STATE_DIR:-${HERMES_HOME:-${OPENCLAW_HOME:-/opt/data}}}"
WANT_TS="${PERKOS_RESTORE_TS:-}"

[[ -n "$S3_URI" ]] || skip "PERKOS_HIBERNATION_S3_URI unset" "no S3 URI"
case "$S3_URI" in */) ;; *) S3_URI="${S3_URI}/" ;; esac

# One-shot point-in-time directive. The API's restore endpoint writes the chosen
# snapshot timestamp to <prefix>restore-directive. We consume it (read here,
# delete after a successful restore) so the point-in-time restore happens
# EXACTLY once — baking the ts into the task-def env instead would re-restore
# the same snapshot on every container restart, silently reverting newer work.
# (PERKOS_RESTORE_TS still works for ad-hoc/manual use and takes precedence.)
DIRECTIVE_URI="${S3_URI}restore-directive"
CONSUME_DIRECTIVE=""
if [[ -z "$WANT_TS" ]]; then
  D="$(aws s3 cp "$DIRECTIVE_URI" - 2>/dev/null | tr -dc 'A-Za-z0-9' || true)"
  if [[ -n "$D" ]]; then
    WANT_TS="$D"
    CONSUME_DIRECTIVE=1
    log "restore directive found → point-in-time restore ts=$WANT_TS"
  fi
fi

# Resolve which snapshot to restore.
if [[ -n "$WANT_TS" ]]; then
  TS="$WANT_TS"
else
  TS="$(aws s3 ls "$S3_URI" 2>/dev/null \
        | grep -oE 'state-[0-9A-Z]+\.tar\.enc' \
        | sed -E 's/^state-(.*)\.tar\.enc$/\1/' | sort -r | head -1 || true)"
fi
[[ -n "$TS" ]] || skip "no snapshot found under $S3_URI" "no snapshot"

ENC_KEY="${S3_URI}state-${TS}.tar.enc"
WRAP_KEY="${S3_URI}state-${TS}.key"
TMP_ENC="/tmp/perkos-restore-$$.tar.enc"
TMP_TAR="/tmp/perkos-restore-$$.tar.gz"
TMP_DK="/tmp/perkos-restore-$$.key.bin"
trap 'rm -f "$TMP_ENC" "$TMP_TAR" "$TMP_DK" 2>/dev/null || true' EXIT

# Confirm both objects exist (ciphertext + wrapped key). If a one-shot directive
# points at a since-pruned ts (TOCTOU: the old container's retention prune can
# delete it during the deploy window — the directive object is NOT pruned), do
# NOT wedge: drop the dead directive and fall back to the latest snapshot. Else
# the directive re-fires every boot (PERKOS_RESTORE_TS stays unset) and the agent
# silently runs from blank state forever.
if ! aws s3 ls "$ENC_KEY" >/dev/null 2>&1; then
  if [[ -n "$CONSUME_DIRECTIVE" ]]; then
    log "WARN: directive ts=$TS ciphertext missing — discarding directive, falling back to latest"
    aws s3 rm "$DIRECTIVE_URI" >/dev/null 2>&1 || log "WARN: could not delete dead restore directive"
    CONSUME_DIRECTIVE=""
    TS="$(aws s3 ls "$S3_URI" 2>/dev/null \
          | grep -oE 'state-[0-9A-Z]+\.tar\.enc' \
          | sed -E 's/^state-(.*)\.tar\.enc$/\1/' | sort -r | head -1 || true)"
    [[ -n "$TS" ]] || skip "no snapshot found under $S3_URI" "no snapshot"
    ENC_KEY="${S3_URI}state-${TS}.tar.enc"
    WRAP_KEY="${S3_URI}state-${TS}.key"
    aws s3 ls "$ENC_KEY" >/dev/null 2>&1 || skip "ciphertext $ENC_KEY missing" "no snapshot"
  else
    skip "ciphertext $ENC_KEY missing" "no snapshot"
  fi
fi
aws s3 ls "$WRAP_KEY" >/dev/null 2>&1 || fail "wrapped key $WRAP_KEY missing (snapshot incomplete)"

log "restoring snapshot ts=$TS"
aws s3 cp "$ENC_KEY" "$TMP_ENC" >&2 || fail "download ciphertext failed"

# Unwrap the data key via KMS (binary blob via fileb:// to avoid CLI base64
# ambiguity). The encryption context MUST match what snapshot.sh used.
aws s3 cp "$WRAP_KEY" - 2>/dev/null | base64 -d > "$TMP_DK" || fail "fetch/decode wrapped key failed"
PLAINKEY="$(aws kms decrypt --ciphertext-blob "fileb://${TMP_DK}" \
              --encryption-context "agent=${AGENT_ID}" \
              --query Plaintext --output text 2>/dev/null)" \
  || fail "kms decrypt failed (wrong key/context?)"
[[ -n "$PLAINKEY" ]] || fail "kms decrypt returned empty key"

# Decrypt → tar.gz.
printf '%s' "$PLAINKEY" | openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 \
  -pass stdin -in "$TMP_ENC" -out "$TMP_TAR" 2>/dev/null || fail "decrypt failed"
PLAINKEY=""

mkdir -p "$DEST"
SIZE="$(stat -c '%s' "$TMP_TAR" 2>/dev/null || stat -f '%z' "$TMP_TAR")"
log "extracting ${SIZE} bytes into $DEST"
# tar default overwrites; -p preserves perms (token/key file modes).
tar -xzpf "$TMP_TAR" -C "$DEST" 2>&1 >&2 || fail "untar failed"

log "restore complete (ts=$TS, ${SIZE} bytes)"
# Consume the one-shot directive so the NEXT boot restores latest, not this ts.
# Retry to ride out a transient S3 error/throttle — a surviving directive would
# re-restore this ts on the next boot and silently revert newer work.
if [[ -n "$CONSUME_DIRECTIVE" ]]; then
  rm_ok=""
  for _ in 1 2 3; do
    if aws s3 rm "$DIRECTIVE_URI" >/dev/null 2>&1; then rm_ok=1; break; fi
    sleep 2
  done
  [[ -n "$rm_ok" ]] \
    && log "consumed restore directive" \
    || log "WARN: could not delete restore directive after retries (may re-restore on next boot)"
fi
printf '{"ok":true,"ts":"%s","key":"state-%s.tar.enc","bytes":%s}\n' "$TS" "$TS" "$SIZE"
