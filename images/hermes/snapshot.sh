#!/usr/bin/env bash
# snapshot.sh — generic (Hermes + OpenClaw)
#
# Client-side ENCRYPTED snapshot of the agent's state dir → S3, so a hibernated
# agent can be cloned/restored on wake. Triggered from the API/bridge BEFORE the
# ECS service scales to 0 (NOT the s6 shutdown hook — that's unreliable under s6
# and races Fargate's stopTimeout).
#
# Encryption = envelope: a KMS data key encrypts the tarball locally with
# openssl AES-256-CBC + PBKDF2. S3 only ever stores CIPHERTEXT + the KMS-wrapped
# data key — never plaintext. Decryption requires kms:Decrypt with the per-agent
# encryption context, so an agent can only open its own backups.
# (openssl `enc -aes-256-gcm` is deliberately avoided — its CLI does not emit/
#  verify the GCM auth tag reliably; CBC+PBKDF2 with the random salt openssl
#  manages is the portable, correct choice. AEAD/HMAC is a future hardening.)
#
# Objects written under the prefix, one set per snapshot (timestamped):
#   state-<TS>.tar.enc        ciphertext (gzip'd tar, then AES-256-CBC)
#   state-<TS>.key            KMS-wrapped data key (CiphertextBlob, base64 text)
#   state-<TS>.manifest.json  metadata (runtime/ts/size/alg — NO secrets)
# Restore picks the newest <TS> (normal wake) or a specified one (point-in-time).
# Retention: keep the newest N (PERKOS_BACKUP_RETENTION, default 5).
#
# Inputs (env):
#   PERKOS_HIBERNATION_S3_URI   s3://bucket/<wallet>/<agent>/  (trailing slash)
#   PERKOS_HIBERNATION_KMS_KEY  KMS key id/alias (REQUIRED — we never upload plaintext)
#   PERKOS_AGENT_ID             encryption-context value (agent=<id>)
#   PERKOS_STATE_DIR            source dir; fallback HERMES_HOME / OPENCLAW_HOME / /opt/data
#   PERKOS_RUNTIME              "hermes" | "openclaw" (manifest + excludes)
#   PERKOS_BACKUP_RETENTION     keep last N (default 5)
#
# Emits one JSON line on stdout (the bridge/API parses it). Exit codes:
#   0 ok/no-op · 1 upload/kms fail · 2 tar fail · 3 encrypt fail
#
# STATUS: client-side-crypto path is UNVALIDATED until tested against the real
# KMS key (Phase 1 infra). Run an encrypt→upload→download→decrypt→untar
# round-trip in a container before trusting it. See HIBERNATION-SNAPSHOT-DESIGN.md.
set -euo pipefail

log() { printf '[snapshot] %s\n' "$*" >&2; }
fail() { log "ERROR: $*"; exit "${2:-1}"; }
skip() { log "$1"; printf '{"ok":true,"skipped":true,"reason":"%s"}\n' "$2"; exit 0; }

S3_URI="${PERKOS_HIBERNATION_S3_URI:-}"
KMS_KEY="${PERKOS_HIBERNATION_KMS_KEY:-}"
AGENT_ID="${PERKOS_AGENT_ID:-unknown}"
RUNTIME="${PERKOS_RUNTIME:-hermes}"
RETAIN="${PERKOS_BACKUP_RETENTION:-5}"
SRC="${PERKOS_STATE_DIR:-${HERMES_HOME:-${OPENCLAW_HOME:-/opt/data}}}"

[[ -n "$S3_URI" ]]  || skip "PERKOS_HIBERNATION_S3_URI unset" "no S3 URI"
# Never upload plaintext: a KMS key is mandatory for the client-side envelope.
[[ -n "$KMS_KEY" ]] || skip "PERKOS_HIBERNATION_KMS_KEY unset — refusing to snapshot unencrypted" "no KMS key"
[[ -d "$SRC" ]]     || skip "source dir $SRC missing" "source missing"
case "$S3_URI" in */) ;; *) S3_URI="${S3_URI}/" ;; esac

TS="$(date -u +%Y%m%dT%H%M%SZ)"
TAR="/tmp/perkos-snap-${TS}.tar.gz"
ENC="/tmp/perkos-snap-${TS}.tar.enc"
trap 'rm -f "$TAR" "$ENC" 2>/dev/null || true' EXIT

# Ephemeral + re-injectable-secret excludes (the provisioner re-supplies these).
EXCLUDES=( --exclude='*.sock' --exclude='*.pid' --exclude='./tmp' --exclude='./logs' )
[[ "$RUNTIME" == "hermes" ]] && EXCLUDES+=( --exclude='./.anthropic_oauth.json' )

log "tarring $SRC (runtime=$RUNTIME) → $TAR"
tar -czf "$TAR" "${EXCLUDES[@]}" -C "$SRC" . 2>&1 >&2 || fail "tar failed" 2

# Envelope key: ONE call returns the plaintext key + the wrapped key (same key).
log "generating KMS data key (context agent=$AGENT_ID)"
DK="$(aws kms generate-data-key --key-id "$KMS_KEY" --key-spec AES_256 \
        --encryption-context "agent=${AGENT_ID}" \
        --query '[Plaintext,CiphertextBlob]' --output text 2>/dev/null)" \
  || fail "kms generate-data-key failed"
PLAINKEY="${DK%%	*}"   # before the tab
WRAPPED="${DK##*	}"      # after the tab
[[ -n "$PLAINKEY" && -n "$WRAPPED" && "$PLAINKEY" != "$WRAPPED" ]] \
  || fail "kms data key parse failed"

# Encrypt locally. The base64 data key is the passphrase; openssl derives the
# AES key via PBKDF2 with a random salt it writes into the output header.
log "encrypting → $ENC (AES-256-CBC + PBKDF2)"
printf '%s' "$PLAINKEY" | openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt \
  -pass stdin -in "$TAR" -out "$ENC" 2>/dev/null || fail "encrypt failed" 3
PLAINKEY=""   # drop the plaintext key from the environment immediately

SIZE="$(stat -c '%s' "$ENC" 2>/dev/null || stat -f '%z' "$ENC")"
BASE="${S3_URI}state-${TS}"

log "uploading ciphertext (${SIZE} bytes) + wrapped key + manifest under ${BASE}"
printf '%s' "$WRAPPED" | aws s3 cp - "${BASE}.key" >&2 || fail "upload wrapped key failed"
aws s3 cp "$ENC" "${BASE}.tar.enc" >&2 || fail "upload ciphertext failed"
printf '{"schemaVersion":1,"runtime":"%s","agentId":"%s","ts":"%s","alg":"AES-256-CBC+PBKDF2","encrypted":true,"bytes":%s}\n' \
  "$RUNTIME" "$AGENT_ID" "$TS" "$SIZE" \
  | aws s3 cp - "${BASE}.manifest.json" >&2 || log "manifest upload failed (non-fatal)"

# Retention: keep the newest N timestamped sets, delete the rest.
log "pruning to last ${RETAIN}"
mapfile -t STAMPS < <(
  aws s3 ls "$S3_URI" 2>/dev/null \
    | grep -oE 'state-[0-9A-Z]+\.tar\.enc' \
    | sed -E 's/^state-(.*)\.tar\.enc$/\1/' | sort -r
)
if (( ${#STAMPS[@]} > RETAIN )); then
  for old in "${STAMPS[@]:$RETAIN}"; do
    aws s3 rm "${S3_URI}state-${old}.tar.enc"       >/dev/null 2>&1 || true
    aws s3 rm "${S3_URI}state-${old}.key"           >/dev/null 2>&1 || true
    aws s3 rm "${S3_URI}state-${old}.manifest.json" >/dev/null 2>&1 || true
    log "pruned state-${old}"
  done
fi

log "snapshot complete (${SIZE} bytes, ts=${TS})"
printf '{"ok":true,"ts":"%s","key":"state-%s.tar.enc","bytes":%s,"encrypted":true}\n' \
  "$TS" "$TS" "$SIZE"
