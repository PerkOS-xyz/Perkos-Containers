#!/usr/bin/env bash
# Local-only unit tests for snapshot.sh / restore.sh.
#
# These cover the paths that don't need a real S3:
#   1. No S3 URI → both scripts skip with JSON status (no-op)
#   2. Missing source dir → snapshot skips
#
# The AWS-touching paths (tar + upload + download + untar) are covered
# by the smoke test against a localstack or real account separately.
#
# Designed to run in CI on every push.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SNAPSHOT="$REPO_ROOT/images/hermes/snapshot.sh"
RESTORE="$REPO_ROOT/images/hermes/restore.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  ✗ %s\n' "$*" >&2; }

# Each test runs in a sub-shell so env tweaks don't leak.
test_snapshot_noop_when_uri_unset() {
  echo "snapshot.sh no-op when PERKOS_HIBERNATION_S3_URI is unset"
  local out
  out="$(env -u PERKOS_HIBERNATION_S3_URI HERMES_HOME=/tmp/does-not-exist bash "$SNAPSHOT" 2>/dev/null)"
  if echo "$out" | grep -qE '"skipped":\s*true'; then
    pass "exit code 0 + skipped JSON"
  else
    fail "expected '\"skipped\": true' in output, got: $out"
  fi
}

test_restore_noop_when_uri_unset() {
  echo "restore.sh no-op when PERKOS_HIBERNATION_S3_URI is unset"
  local out
  out="$(env -u PERKOS_HIBERNATION_S3_URI HERMES_HOME=/tmp/x bash "$RESTORE" 2>/dev/null)"
  if echo "$out" | grep -qE '"skipped":\s*true'; then
    pass "exit code 0 + skipped JSON"
  else
    fail "expected '\"skipped\": true' in output, got: $out"
  fi
}

test_snapshot_skips_when_source_missing() {
  echo "snapshot.sh skips when source dir missing"
  local tmp
  tmp="$(mktemp -d)"
  rmdir "$tmp"  # delete so it's a missing dir
  local out
  # A KMS key is required before the source check (we never snapshot
  # unencrypted), so set a dummy one to reach the source-missing path.
  out="$(PERKOS_HIBERNATION_S3_URI=s3://x/y/ PERKOS_HIBERNATION_KMS_KEY=alias/test HERMES_HOME="$tmp" bash "$SNAPSHOT" 2>/dev/null || true)"
  if echo "$out" | grep -qE '"reason":\s*"source missing"'; then
    pass "no source dir → graceful skip"
  else
    fail "expected source-missing skip, got: $out"
  fi
}

test_snapshot_skips_when_no_kms() {
  echo "snapshot.sh refuses (skips) when no KMS key — never uploads plaintext"
  local out
  out="$(PERKOS_HIBERNATION_S3_URI=s3://x/y/ env -u PERKOS_HIBERNATION_KMS_KEY HERMES_HOME=/tmp bash "$SNAPSHOT" 2>/dev/null || true)"
  if echo "$out" | grep -qE '"reason":\s*"no KMS key"'; then
    pass "no KMS key → graceful skip (no plaintext upload)"
  else
    fail "expected no-KMS skip, got: $out"
  fi
}

test_snapshot_exit_codes() {
  echo "snapshot.sh exits 0 on no-op paths"
  if env -u PERKOS_HIBERNATION_S3_URI bash "$SNAPSHOT" >/dev/null 2>&1; then
    pass "exit 0 when URI unset"
  else
    fail "expected exit 0, got non-zero"
  fi
}

test_help_runs() {
  echo "scripts have valid bash syntax"
  if bash -n "$SNAPSHOT"; then pass "snapshot.sh syntax OK"; else fail "snapshot.sh syntax error"; fi
  if bash -n "$RESTORE"; then pass "restore.sh syntax OK"; else fail "restore.sh syntax error"; fi
}

test_help_runs
test_snapshot_noop_when_uri_unset
test_restore_noop_when_uri_unset
test_snapshot_skips_when_source_missing
test_snapshot_skips_when_no_kms
test_snapshot_exit_codes

echo
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then exit 1; fi
