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
#   4. Run /init (s6-overlay) as a CHILD (not exec), trap SIGTERM,
#      and on shutdown: stop upstream → wait → snapshot → exit.
#
# Why /init (not /opt/hermes/docker/entrypoint.sh):
#   Upstream Hermes deprecated docker/entrypoint.sh — it now only
#   runs the stage2 cont-init hook and does NOT exec the CMD, so a
#   container started via that wrapper boots a half-initialized
#   environment (missing s6-setuidgid in PATH) and exits before the
#   agent ever starts. The real entrypoint is /init, which handles
#   the full s6-overlay bootstrap (stage1 + stage2) and then exec's
#   the image's default CMD (the `hermes` binary). We invoke /init
#   directly so the s6-setuidgid + service-supervision tree comes
#   up correctly. SIGTERM forwarding still works: s6's /init catches
#   the signal we send to its PID and gracefully shuts down all
#   supervised children before exiting.
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
mkdir -p "$HERMES_HOME" "$HERMES_HOME/skills" "$HERMES_HOME/plugins/platforms"

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

# Stage messaging gateway platform adapters. We only stage a platform
# if it has the env vars it needs — Hermes's PlatformRegistry won't
# instantiate an adapter without required_env (declared in each
# plugin.yaml), but staging the directory unconditionally would still
# eat startup time scanning a plugin we'll never use. Conditional
# copy keeps the loader noise out of the agent's log for inactive
# gateways.
if [ -d /opt/perkos-platforms/farcaster ] && [ -n "${FARCASTER_NEYNAR_API_KEY:-}" ]; then
  rm -rf "$HERMES_HOME/plugins/platforms/farcaster"
  cp -r /opt/perkos-platforms/farcaster "$HERMES_HOME/plugins/platforms/farcaster"
  echo "perkos-entrypoint: staged farcaster platform plugin"
fi

echo "perkos-entrypoint: wrote $HERMES_HOME/config.yaml (agent=$PERKOS_AGENT_NAME id=$PERKOS_AGENT_ID)"
echo "perkos-entrypoint: skills/ contains: $(ls "$HERMES_HOME/skills" 2>/dev/null | tr '\n' ' ')"
echo "perkos-entrypoint: plugins/platforms/ contains: $(ls "$HERMES_HOME/plugins/platforms" 2>/dev/null | tr '\n' ' ')"

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

echo "perkos-entrypoint: delegating to /init (s6-overlay)..."

# Fork (not exec) s6-overlay's /init so we keep PID 1 — that's how
# the SIGTERM trap survives long enough to snapshot. s6 forwards
# our signal to its supervised children (the hermes binary + any
# sidecar services), waits for them to drain, then exits. ECS
# Fargate's task stopTimeout gives us a generous budget (the
# miniapp sets it to 300s) so s6's graceful shutdown + our tar +
# S3 upload comfortably fit.
/init "$@" &
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
