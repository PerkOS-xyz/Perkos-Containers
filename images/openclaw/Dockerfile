# syntax=docker/dockerfile:1.7
#
# OpenClaw + PerkOS wrapper.
#
# We layer on top of the official ghcr.io/openclaw/openclaw image — not a
# fork. That means upstream changes ride for free: bump OPENCLAW_TAG to
# upgrade. We only add:
#
#   1. A baseline ~/.openclaw/openclaw.json template that hard-codes the
#      PerkOS-LLM ollama provider block (api.llm.perkos.xyz). Users can
#      still override with BYOK env vars at runtime.
#   2. An entrypoint shim that materializes the template from env vars
#      on container start (PERKOS_AGENT_ID, PERKOS_LLM_API_KEY, etc.).
#
# The PerkOS-A2A bridge runs as a separate container in the ECS task,
# not inside this image. Splits concerns so we can ship A2A protocol
# changes without rebuilding the OpenClaw image.

# OPENCLAW_REF is the full base reference. Locally it defaults to the
# moving `:latest` tag; CI resolves `:latest` to a concrete @sha256 digest
# and passes it here so each weekly release is reproducible. OPENCLAW_TAG /
# OPENCLAW_VERSION stay around purely for the human-readable labels.
ARG OPENCLAW_REF=ghcr.io/openclaw/openclaw:latest
FROM ${OPENCLAW_REF}

# Re-declare so they're available in the runtime stage (for labels).
ARG OPENCLAW_TAG=latest
ARG OPENCLAW_REF=ghcr.io/openclaw/openclaw:latest
ARG OPENCLAW_VERSION=

USER root

# tini is already in the upstream image. We only need jq for the
# entrypoint template substitution.
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends jq && \
    rm -rf /var/lib/apt/lists/*

# Baseline config — templated by docker-entrypoint.sh at boot. Values
# wrapped in __ENV_VAR__ get replaced from container env.
COPY --chown=node:node config/openclaw.template.json /opt/perkos/openclaw.template.json
# Bundled PerkOS skills (e.g. perkos-platform-tools). Baked under
# /opt/perkos-skills/ and copied into the agent's workspace skills dir at
# boot by the entrypoint, where OpenClaw auto-discovers them.
COPY --chown=node:node skills /opt/perkos-skills
COPY docker-entrypoint.sh /usr/local/bin/perkos-entrypoint.sh
RUN chmod 755 /usr/local/bin/perkos-entrypoint.sh

# PerkOS metadata
LABEL org.opencontainers.image.title="PerkOS-OpenClaw" \
      org.opencontainers.image.description="OpenClaw with PerkOS-LLM provider + ECS-ready config" \
      org.opencontainers.image.source="https://github.com/PerkOS-xyz/Perkos-Containers" \
      perkos.runtime="openclaw" \
      perkos.upstream-tag="${OPENCLAW_TAG}" \
      perkos.upstream-ref="${OPENCLAW_REF}" \
      perkos.upstream-version="${OPENCLAW_VERSION}"

USER node

# Defaults — overridable at runtime via -e
ENV PERKOS_LLM_BASE_URL=https://api.llm.perkos.xyz \
    PERKOS_LLM_DEFAULT_MODEL=kimi-k2.6:cloud \
    OPENCLAW_CONFIG_PATH=/home/node/.openclaw/openclaw.json

EXPOSE 18789

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:18789/healthz').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

ENTRYPOINT ["tini", "-s", "--", "perkos-entrypoint.sh"]
CMD ["node", "openclaw.mjs", "gateway", "--bind", "lan"]
