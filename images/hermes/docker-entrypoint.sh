#!/bin/sh
# PerkOS-Hermes entrypoint.
#
# Runs as root (upstream entrypoint will drop privileges later). We do
# three things here, then hand off to upstream:
#
#   1. Render /opt/data/config.yaml from PERKOS_* env vars
#   2. Install the perkos-platform-tools skill into $HERMES_HOME/skills/
#      where Hermes auto-discovers it
#   3. exec /opt/hermes/docker/entrypoint.sh — which chown's HERMES_HOME,
#      drops to the hermes user via gosu, sources the venv, and execs
#      `hermes` with whatever args were passed
#
# Required env vars (we fail-fast if missing rather than letting Hermes
# start with a half-baked config and produce confusing later errors):
#   - PERKOS_AGENT_ID
#   - PERKOS_AGENT_NAME
#   - PERKOS_LLM_API_KEY

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

echo "perkos-entrypoint: delegating to upstream entrypoint..."

# Hand off. Upstream's entrypoint at /opt/hermes/docker/entrypoint.sh
# handles HERMES_UID/GID remapping, chown of HERMES_HOME, venv activation,
# and finally exec's `hermes` with whatever args we got. Passing no args
# yields upstream's legacy default (`hermes` with no subcommand, which
# starts the agent in its default mode).
exec /opt/hermes/docker/entrypoint.sh "$@"
