#!/bin/sh
# PerkOS-OpenClaw entrypoint.
#
# Materializes /opt/perkos/openclaw.template.json into
# $OPENCLAW_CONFIG_PATH (default ~/.openclaw/openclaw.json) by substituting
# __FOO__ placeholders with the matching $FOO env var. Refuses to start
# if a required var is unset, since OpenClaw would silently fall back to
# its built-in defaults — which on PerkOS infra means "no LLM source" and
# the agent would loop on `429 No provider configured`.
#
# After templating, exec into the upstream CMD (passed in by Dockerfile).

set -eu

CONFIG_DIR="$(dirname "$OPENCLAW_CONFIG_PATH")"
mkdir -p "$CONFIG_DIR"

# Generate a gateway API key on first boot if not provided. Persisted in
# the config dir so container restarts reuse the same key (otherwise any
# other process talking to this gateway would lose connection).
if [ -z "${PERKOS_GATEWAY_API_KEY:-}" ]; then
  GATEWAY_KEY_FILE="$CONFIG_DIR/.gateway-api-key"
  if [ -f "$GATEWAY_KEY_FILE" ]; then
    PERKOS_GATEWAY_API_KEY="$(cat "$GATEWAY_KEY_FILE")"
  else
    PERKOS_GATEWAY_API_KEY="gk_$(tr -dc 'a-f0-9' < /dev/urandom | head -c 48)"
    printf '%s' "$PERKOS_GATEWAY_API_KEY" > "$GATEWAY_KEY_FILE"
    chmod 600 "$GATEWAY_KEY_FILE"
  fi
  export PERKOS_GATEWAY_API_KEY
fi

# Required vars — fail fast.
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

# Normalize per-gateway *_ENABLED env vars (set by perkos-app's
# ecsProvision when the wallet enables that gateway in /agents/new)
# into the strict "true" / "false" strings the template substitution
# expects. Accept the same truthy values the catalog declares.
truthy() {
  case "${1:-}" in
    true|TRUE|True|1|yes|YES|Yes) echo true ;;
    *) echo false ;;
  esac
}

TELEGRAM_PLUGIN_ENABLED=$(truthy "${TELEGRAM_ENABLED:-}")
SLACK_PLUGIN_ENABLED=$(truthy "${SLACK_ENABLED:-}")
DISCORD_PLUGIN_ENABLED=$(truthy "${DISCORD_ENABLED:-}")

# Substitute __FOO__ placeholders. jq is in the image already.
#
# Plugin enabled flags are substituted as STRINGS first and then
# coerced to JSON booleans in a second pass — gsub only operates on
# strings, but the openclaw plugin config requires a real `true`/
# `false`, not the literal string "true". Two-step pattern is
# simpler than mixing jq filter modes mid-pipeline.
jq \
  --arg agent_id    "$PERKOS_AGENT_ID" \
  --arg agent_name  "$PERKOS_AGENT_NAME" \
  --arg base_url    "$PERKOS_LLM_BASE_URL" \
  --arg api_key     "$PERKOS_LLM_API_KEY" \
  --arg model       "$PERKOS_LLM_DEFAULT_MODEL" \
  --arg gateway_key "$PERKOS_GATEWAY_API_KEY" \
  --arg telegram_plugin_enabled "$TELEGRAM_PLUGIN_ENABLED" \
  --arg slack_plugin_enabled    "$SLACK_PLUGIN_ENABLED" \
  --arg discord_plugin_enabled  "$DISCORD_PLUGIN_ENABLED" \
  '
  (..|strings) |= (
    gsub("__PERKOS_AGENT_ID__";       $agent_id)
    | gsub("__PERKOS_AGENT_NAME__";   $agent_name)
    | gsub("__PERKOS_LLM_BASE_URL__"; $base_url)
    | gsub("__PERKOS_LLM_API_KEY__";  $api_key)
    | gsub("__PERKOS_LLM_DEFAULT_MODEL__"; $model)
    | gsub("__PERKOS_GATEWAY_API_KEY__";   $gateway_key)
    | gsub("__TELEGRAM_PLUGIN_ENABLED__";  $telegram_plugin_enabled)
    | gsub("__SLACK_PLUGIN_ENABLED__";     $slack_plugin_enabled)
    | gsub("__DISCORD_PLUGIN_ENABLED__";   $discord_plugin_enabled)
  )
  | if .plugins.entries.telegram.enabled then
      .plugins.entries.telegram.enabled |= (. == "true")
    else . end
  | if .plugins.entries.slack.enabled then
      .plugins.entries.slack.enabled |= (. == "true")
    else . end
  | if .plugins.entries.discord.enabled then
      .plugins.entries.discord.enabled |= (. == "true")
    else . end
  ' /opt/perkos/openclaw.template.json > "$OPENCLAW_CONFIG_PATH"

chmod 600 "$OPENCLAW_CONFIG_PATH"

echo "perkos-entrypoint: wrote $OPENCLAW_CONFIG_PATH (agent=$PERKOS_AGENT_NAME id=$PERKOS_AGENT_ID)"
echo "perkos-entrypoint: channel plugins — telegram=$TELEGRAM_PLUGIN_ENABLED slack=$SLACK_PLUGIN_ENABLED discord=$DISCORD_PLUGIN_ENABLED"

exec "$@"
