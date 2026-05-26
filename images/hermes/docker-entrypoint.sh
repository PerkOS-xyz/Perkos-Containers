#!/bin/bash
# PerkOS-Hermes entrypoint.
#
# Runs as root (upstream entrypoint will drop privileges later). We do
# four things here, then hand off to upstream:
#
#   1. Render /opt/data/config.yaml from PERKOS_* env vars
#   2. Install the perkos-platform-tools skill into $HERMES_HOME/skills/
#      where Hermes auto-discovers it
#   3. If PERKOS_HIBERNATION_S3_URI is set, restore the latest snapshot
#      into HERMES_HOME BEFORE upstream starts. No-op on first launch.
#   4. Run /opt/hermes/docker/entrypoint.sh as a CHILD (not exec), trap
#      SIGTERM, and on shutdown: stop upstream → wait → snapshot → exit
#
# Bash (not sh): we need `trap`, `wait $!`, and `kill -TERM "$PID"`.
#
# Required env vars (we fail-fast if missing rather than letting Hermes
# start with a half-baked config and produce confusing later errors):
#   - PERKOS_AGENT_ID
#   - PERKOS_AGENT_NAME
#   - PERKOS_LLM_API_KEY
#
# Optional env vars for hibernation:
#   - PERKOS_HIBERNATION_S3_URI  e.g. s3://perkos-agent-snapshots-prod/<wallet>/<name>/
#                                When set: restore on boot, snapshot on SIGTERM.
#                                When unset: both scripts no-op gracefully.

set -eu

require() {
  eval "val=\${$1:-}"
  if [ -z "$val" ]; then
    echo "perkos-entrypoint: required env $1 is not set" >&2
    exit 1
  fi
}

require PERKOS_AGENT_ID
require PERKOS_AGENT_NAME
require PERKOS_LLM_API_KEY

HERMES_HOME="${HERMES_HOME:-/opt/data}"
mkdir -p "$HERMES_HOME" "$HERMES_HOME/skills"

# Render the config Hermes reads at startup. envsubst expands ${PERKOS_*}
# in the template; literal $ signs in the template must be escaped as $$.
# Upstream entrypoint also writes a default cli-config.yaml.example to
# $HERMES_HOME/config.yaml if absent — we always overwrite so the env
# vars are the source of truth for the PerkOS deploy.
envsubst < /opt/perkos/hermes.template.yaml > "$HERMES_HOME/config.yaml"
chmod 644 "$HERMES_HOME/config.yaml"

# Stage our skill into the place Hermes scans. We baked it into
# /opt/perkos-skills/ in the Dockerfile (under root) and copy it now into
# HERMES_HOME/skills/ before upstream chowns the tree. Upstream's
# subsequent `chown -R hermes:hermes "$HERMES_HOME"` will hand it to the
# hermes user automatically.
if [ -d /opt/perkos-skills/perkos-platform-tools ]; then
  rm -rf "$HERMES_HOME/skills/perkos-platform-tools"
  cp -r /opt/perkos-skills/perkos-platform-tools "$HERMES_HOME/skills/perkos-platform-tools"
fi

echo "perkos-entrypoint: wrote $HERMES_HOME/config.yaml (agent=$PERKOS_AGENT_NAME id=$PERKOS_AGENT_ID)"
echo "perkos-entrypoint: skills/ contains: $(ls "$HERMES_HOME/skills" 2>/dev/null | tr '\n' ' ')"

# We created HERMES_HOME + skills dir as root above. Upstream entrypoint
# detects mismatched ownership and chowns to the `hermes` user (UID 10000)
# before dropping privileges — but its `mkdir -p $HERMES_HOME/skills/...`
# happens AFTER the drop, so any subdir under skills/ that doesn't exist
# yet gets blocked by our root-owned skills/ parent unless we chown
# pre-emptively. Doing it here keeps the timing right.
chown -R 10000:10000 "$HERMES_HOME" 2>/dev/null || \
  echo "perkos-entrypoint: chown HERMES_HOME failed (rootless container?) — upstream will retry"

# Restore a stashed snapshot if one exists. No-op on first ever launch
# or when PERKOS_HIBERNATION_S3_URI is unset. We run this as root before
# upstream's chown so the restored files end up with the right owner.
echo "perkos-entrypoint: checking for hibernation snapshot..."
/usr/local/bin/perkos-restore.sh || \
  echo "perkos-entrypoint: restore failed (continuing with fresh state)"

echo "perkos-entrypoint: delegating to upstream entrypoint..."

# Fork (not exec) upstream so we keep PID 1 — that's how the SIGTERM
# trap survives long enough to snapshot. We forward the signal to
# upstream first, wait for it to drain, then snapshot, then exit. ECS
# Fargate's task stopTimeout gives us a generous budget (the miniapp
# sets it to 300s) so a small tar+upload comfortably fits.
/opt/hermes/docker/entrypoint.sh "$@" &
UPSTREAM_PID=$!

shutdown_handler() {
  echo "perkos-entrypoint: SIGTERM received, stopping upstream (pid=$UPSTREAM_PID)..."
  if kill -0 "$UPSTREAM_PID" 2>/dev/null; then
    kill -TERM "$UPSTREAM_PID" 2>/dev/null || true
    # Wait for upstream to finish its own shutdown. Once it's gone,
    # HERMES_HOME is in a consistent state for snapshotting.
    wait "$UPSTREAM_PID" 2>/dev/null || true
  fi
  echo "perkos-entrypoint: upstream stopped, taking final snapshot..."
  /usr/local/bin/perkos-snapshot.sh || \
    echo "perkos-entrypoint: snapshot failed (state will be lost on wake)"
  echo "perkos-entrypoint: clean shutdown complete"
  exit 0
}
trap shutdown_handler TERM INT

# `wait` is interruptible by signals — when our trap fires it interrupts
# this wait, runs the handler, then exits cleanly. Without the explicit
# `wait $UPSTREAM_PID`, signals would be ignored until upstream returned.
wait "$UPSTREAM_PID"
RC=$?
echo "perkos-entrypoint: upstream exited with code $RC (no SIGTERM seen)"
exit "$RC"
