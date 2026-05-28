#!/command/with-contenv bash
# PerkOS boot hook for the Hermes image.
#
# Runs as part of s6-overlay's stage2 cont-init phase: AFTER the s6
# environment is set up (so s6-* binaries are in PATH) and BEFORE
# any supervised services start (so $HERMES_HOME is ready when the
# hermes binary launches). Runs as root; s6 will drop privileges
# for the services it supervises later.
#
# What we do here, in order:
#   1. Fail fast if the required env isn't set (PERKOS_AGENT_ID,
#      PERKOS_AGENT_NAME, PERKOS_LLM_API_KEY). A clean failure here
#      surfaces in `docker logs` instantly; without it, a missing
#      env causes a deep error inside hermes that's much harder to
#      triage.
#   2. Render $HERMES_HOME/config.yaml from /opt/perkos/hermes.template.yaml
#      via envsubst — the same flow the deprecated perkos-entrypoint.sh
#      used to do.
#   3. Stage the perkos-platform-tools skill into $HERMES_HOME/skills/.
#   4. Conditionally stage gateway platform plugins (currently:
#      farcaster) into $HERMES_HOME/plugins/platforms/ when their
#      required env vars are set. Unconfigured gateways stay
#      unstaged so the plugin scan stays quiet.
#   5. chown $HERMES_HOME to the hermes user (UID 10000) so the
#      service can write inside it after the privilege drop.
#   6. Restore the latest snapshot from S3 if PERKOS_HIBERNATION_S3_URI
#      is set; no-op otherwise.
#
# Why a shebang of /command/with-contenv bash:
#   s6-overlay's `with-contenv` wrapper passes the container env into
#   the script (cont-init.d/* scripts otherwise run with an empty
#   env per s6 convention). Without it our PERKOS_* env reads would
#   come back empty and step 1 would always fail.
#
# Exit codes:
#   0  → continue boot. s6 will start supervised services.
#   ≠0 → s6 aborts boot; the container exits with that code. ECS
#        will restart per its task definition policy.

set -eu

require() {
  eval "val=\${$1:-}"
  if [ -z "$val" ]; then
    echo "perkos-boot: required env $1 is not set" >&2
    exit 1
  fi
}

require PERKOS_AGENT_ID
require PERKOS_AGENT_NAME
require PERKOS_LLM_API_KEY

HERMES_HOME="${HERMES_HOME:-/opt/data}"
mkdir -p "$HERMES_HOME" "$HERMES_HOME/skills" "$HERMES_HOME/plugins/platforms"

# Render the config Hermes reads at startup. envsubst expands
# ${PERKOS_*} in the template; literal $ signs in the template must
# be escaped as $$. We always overwrite so the env vars are the
# source of truth for this PerkOS deploy.
envsubst < /opt/perkos/hermes.template.yaml > "$HERMES_HOME/config.yaml"
chmod 644 "$HERMES_HOME/config.yaml"

# Stage the perkos-platform-tools skill — Hermes auto-discovers
# skills under $HERMES_HOME/skills/ at startup.
if [ -d /opt/perkos-skills/perkos-platform-tools ]; then
  rm -rf "$HERMES_HOME/skills/perkos-platform-tools"
  cp -r /opt/perkos-skills/perkos-platform-tools "$HERMES_HOME/skills/perkos-platform-tools"
fi

# Gateway platform plugins — only stage when configured, so an
# unconfigured gateway doesn't show up in Hermes's plugin scan log.
if [ -d /opt/perkos-platforms/farcaster ] && [ -n "${FARCASTER_NEYNAR_API_KEY:-}" ]; then
  rm -rf "$HERMES_HOME/plugins/platforms/farcaster"
  cp -r /opt/perkos-platforms/farcaster "$HERMES_HOME/plugins/platforms/farcaster"
  echo "perkos-boot: staged farcaster platform plugin"
fi

echo "perkos-boot: wrote $HERMES_HOME/config.yaml (agent=$PERKOS_AGENT_NAME id=$PERKOS_AGENT_ID)"
echo "perkos-boot: skills/ contains: $(ls "$HERMES_HOME/skills" 2>/dev/null | tr '\n' ' ')"
echo "perkos-boot: plugins/platforms/ contains: $(ls "$HERMES_HOME/plugins/platforms" 2>/dev/null | tr '\n' ' ')"

# chown so the hermes user (UID 10000) can write inside HERMES_HOME
# after s6 drops privs. Failure here is tolerated for rootless
# containers — upstream's own init handles ownership too.
chown -R 10000:10000 "$HERMES_HOME" 2>/dev/null || \
  echo "perkos-boot: chown HERMES_HOME failed (rootless container?) — upstream will retry"

# Restore a stashed snapshot if one exists. No-op on first launch
# or when PERKOS_HIBERNATION_S3_URI is unset. Runs as root before
# the privilege drop so restored files end up with the right owner.
echo "perkos-boot: checking for hibernation snapshot..."
/usr/local/bin/perkos-restore.sh || \
  echo "perkos-boot: restore failed (continuing with fresh state)"
