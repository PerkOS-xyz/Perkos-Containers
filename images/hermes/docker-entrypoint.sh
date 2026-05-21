#!/bin/sh
# PerkOS-Hermes entrypoint.
# Mirrors the OpenClaw entrypoint shape, but writes a YAML profile under
# ~/.hermes/profiles/<HERMES_PROFILE_NAME>/config.yaml.

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

PROFILE_DIR="$HOME/.hermes/profiles/${HERMES_PROFILE_NAME}"
mkdir -p "$PROFILE_DIR"

envsubst < /opt/perkos/hermes.template.yaml > "$PROFILE_DIR/config.yaml"
chmod 600 "$PROFILE_DIR/config.yaml"

echo "perkos-entrypoint: wrote $PROFILE_DIR/config.yaml (agent=$PERKOS_AGENT_NAME id=$PERKOS_AGENT_ID)"

exec "$@"
