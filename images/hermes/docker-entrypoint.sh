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
mkdir -p "$HERMES_HOME" "$HERMES_HOME/skills" "$HERMES_HOME/plugins/platforms"

# Render the config Hermes reads at startup. envsubst expands ${PERKOS_*}
# in the template; literal $ signs in the template must be escaped as $$.
# Upstream entrypoint also writes a default cli-config.yaml.example to
# $HERMES_HOME/config.yaml if absent — we always overwrite so the env
# vars are the source of truth for the PerkOS deploy.
#
# Plain envsubst does NOT support `${VAR:-default}` fallback syntax
# (that's a bash-only extension). The platforms block in the template
# expects toggles to render as the literal strings "true" / "false"
# so Hermes parses them as YAML booleans, not as the raw placeholder
# text. Pre-normalize each toggle to a sane default if unset, then
# export it so envsubst sees a real value and replaces `${VAR}`.
#
# truthy: accept the lenient inputs the catalog declares (true/1/yes),
# normalize to the strict "true"/"false" strings Hermes expects.
truthy() {
  case "${1:-}" in
    true|TRUE|True|1|yes|YES|Yes) echo true ;;
    *) echo false ;;
  esac
}

# api_server is enabled by default — it's the HTTP surface the
# perkos-a2a bridge sidecar posts to. Operator can opt out with
# API_SERVER_ENABLED=false.
API_SERVER_ENABLED=$(truthy "${API_SERVER_ENABLED:-true}")
API_SERVER_HOST="${API_SERVER_HOST:-0.0.0.0}"
API_SERVER_PORT="${API_SERVER_PORT:-8642}"

# Messaging gateways default OFF — a wallet enables them via the
# /agents/new wizard which sets *_ENABLED via ecsProvision.
TELEGRAM_ENABLED=$(truthy "${TELEGRAM_ENABLED:-}")
TELEGRAM_WEBHOOK_URL="${TELEGRAM_WEBHOOK_URL:-}"
SLACK_ENABLED=$(truthy "${SLACK_ENABLED:-}")
SLACK_CHANNEL_ID="${SLACK_CHANNEL_ID:-}"
FARCASTER_ENABLED=$(truthy "${FARCASTER_ENABLED:-}")

export API_SERVER_ENABLED API_SERVER_HOST API_SERVER_PORT
export TELEGRAM_ENABLED TELEGRAM_WEBHOOK_URL
export SLACK_ENABLED SLACK_CHANNEL_ID
export FARCASTER_ENABLED

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

# Persona from env (PerkOS template SOUL).
#
# The launcher renders the chosen template's soul to markdown and the
# provisioner base64's it into PERKOS_AGENT_SOUL_B64. Decode it to
# $HERMES_HOME/SOUL.md so the agent boots with its persona. Hermes
# reloads SOUL.md fresh each message. Takes precedence over the baked
# Assistant SOUL below; absent → fall through to defaults.
if [ -n "${PERKOS_AGENT_SOUL_B64:-}" ]; then
  if printf '%s' "$PERKOS_AGENT_SOUL_B64" | base64 -d > "${HERMES_HOME:-/opt/data}/SOUL.md" 2>/dev/null; then
    chown 10000:10000 "${HERMES_HOME:-/opt/data}/SOUL.md" 2>/dev/null || true
    echo "perkos-entrypoint: persona SOUL.md written from PERKOS_AGENT_SOUL_B64 ($(wc -c < "${HERMES_HOME:-/opt/data}/SOUL.md") bytes)"
  else
    echo "perkos-entrypoint: WARNING failed to decode PERKOS_AGENT_SOUL_B64 — using default persona"
  fi
fi

# Persist the PerkOS Assistant SOUL across rebuilds.
#
# If /opt/perkos-assistant/SOUL.md exists in the image, concatenate it
# with the runbook files at /opt/perkos-assistant/runbook/*.md and write
# the combined output to $HERMES_HOME/SOUL.md (default /opt/data/SOUL.md).
# Hermes loads SOUL.md fresh each message, so the new content takes
# effect on the very next chat without a runtime restart.
#
# Only kicks in for the PerkOS-Assistant agent (PERKOS_AGENT_NAME=
# "PerkOS-Assistant") AND when no env-provided persona already won above.

if [ -z "${PERKOS_AGENT_SOUL_B64:-}" ] && [ "${PERKOS_AGENT_NAME:-}" = "PerkOS-Assistant" ] && [ -f /opt/perkos-assistant/SOUL.md ]; then
  {
    cat /opt/perkos-assistant/SOUL.md
    if [ -d /opt/perkos-assistant/runbook ]; then
      for f in /opt/perkos-assistant/runbook/*.md; do
        [ -f "$f" ] || continue
        echo
        echo "## File: $(basename "$f")"
        echo
        cat "$f"
        echo
      done
    fi
  } > "${HERMES_HOME:-/opt/data}/SOUL.md"
  chown hermes:hermes "${HERMES_HOME:-/opt/data}/SOUL.md" 2>/dev/null || true
  echo "perkos-entrypoint: PerkOS-Assistant SOUL installed at ${HERMES_HOME:-/opt/data}/SOUL.md"
fi

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

# Upstream Hermes oscillates between two ENTRYPOINT shapes across
# releases:
#
#   1. s6-overlay: `/init` is the real ENTRYPOINT. It bootstraps the
#      s6 supervision tree and execs CMD itself. `docker/entrypoint.sh`
#      becomes a deprecated shim that crashes when invoked directly
#      because the s6 utilities (`s6-setuidgid`, etc) are only on PATH
#      from inside the supervision tree.
#
#   2. Non-s6: `docker/entrypoint.sh` is the real ENTRYPOINT and execs
#      CMD itself. There is no `/init`.
#
# Detect by probing `/init` and route accordingly. For the s6 case we
# can't keep PID 1 (s6 has to be PID 1 to supervise its services), so
# the snapshot-on-SIGTERM logic ceases to apply for that path —
# Hibernation snapshots in s6 mode need a cont-finish.d hook instead.
# Today the perkos-assistant deploy doesn't set
# PERKOS_HIBERNATION_S3_URI, so this is a no-op in prod; the legacy
# non-s6 path keeps the snapshot trap intact for ECS Fargate hibernation
# clients that still run that variant.

if [ -x /init ] && [ "${PERKOS_BYPASS_S6:-}" != "true" ]; then
  echo "perkos-entrypoint: upstream uses s6-overlay (/init present) — exec /init"
  # exec replaces our shell so /init becomes PID 1. Signal handling is
  # owned by s6 from here on.
  #
  # We deliberately drop "$@" (the CMD) before exec'ing /init. In s6
  # mode the `main-hermes` s6-rc service already starts the gateway
  # daemon at boot, so legacy callers passing CMD ["gateway", "run"]
  # — both our compose file and the CI smoke test — would have their
  # CMD dispatched to s6's `legacy-services`, which runs in a shell
  # context where the hermes Python venv isn't on PATH and `gateway`
  # fails with `not found`. Dropping the CMD lets main-hermes do its
  # job alone and keeps the legacy callers compatible without code
  # changes on their side.
  #
  # TODO: install a cont-finish.d hook that runs perkos-snapshot.sh
  # on graceful shutdown when PERKOS_HIBERNATION_S3_URI is set.
  if [ "$#" -gt 0 ]; then
    echo "perkos-entrypoint: ignoring CMD args ($*) — main-hermes s6 service runs the gateway"
  fi
  exec /init
fi

# Fork (not exec) the legacy upstream entrypoint so we keep PID 1 —
# that's how the SIGTERM trap survives long enough to snapshot. We
# forward the signal to upstream first, wait for it to drain, then
# snapshot, then exit. ECS Fargate's task stopTimeout gives us a
# generous budget (the miniapp sets it to 300s) so a small tar+upload
# comfortably fits.
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
