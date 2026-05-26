# syntax=docker/dockerfile:1.7
#
# Hermes + PerkOS wrapper.
#
# Layers on top of the official nousresearch/hermes-agent image:
#   1. Pre-installs the hermes-perkos plugin (matches the PerkOS-A2A bridge)
#   2. Seeds ~/.hermes/profiles/<name>/config.yaml from env vars on boot
#
# Like the OpenClaw image, the PerkOS-A2A bridge is a sidecar container in
# the ECS task — not embedded here.

ARG HERMES_TAG=latest
FROM nousresearch/hermes-agent:${HERMES_TAG}

ARG HERMES_TAG

USER root

# envsubst + ca-certs for HTTPS to the model providers.
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      gettext-base ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# hermes-perkos plugin from the @perkos/perkos-a2a npm package — it ships
# a Python entrypoint under dist/hermes-plugin.py that Hermes loads.
# Pinned via PERKOS_A2A_VERSION so we can roll forward in CI.
ARG PERKOS_A2A_VERSION=0.9.0
RUN pip install --no-cache-dir "perkos-a2a==${PERKOS_A2A_VERSION}" || \
    echo "perkos-a2a not on PyPI yet; skipping (will mount at runtime)"

COPY config/hermes.template.yaml /opt/perkos/hermes.template.yaml
COPY docker-entrypoint.sh /usr/local/bin/perkos-entrypoint.sh
RUN chmod 755 /usr/local/bin/perkos-entrypoint.sh

# PerkOS Assistant content — SOUL (persona) + runbook (FAQ knowledge).
# Used only when the container is provisioned as the platform identity
# "PerkOS-Assistant" (kind: "platform" on /api/agents/launch). Regular
# user-launched agents ignore /opt/perkos-assistant/ entirely; baking
# the ~50 KB of markdown into every image keeps the deploy uniform.
#
# Source of truth for these files is PerkOS/docs/perkos-assistant/ in
# the main miniapp repo. See perkos-assistant/README.md for the
# manual sync convention (will become a CI sync action later).
COPY perkos-assistant /opt/perkos-assistant

# perkos-platform-tools Hermes skill — currently documentation-only
# (workflows the LLM follows when the runbook applies). Python tool
# handlers land in a follow-up PR after we validate the bootstrap.
# Hermes auto-discovers skills under ~/.hermes/skills/ at startup.
COPY skills/perkos-platform-tools /root/.hermes/skills/perkos-platform-tools

LABEL org.opencontainers.image.title="PerkOS-Hermes" \
      org.opencontainers.image.description="Hermes agent with PerkOS-LLM provider + ECS-ready config" \
      org.opencontainers.image.source="https://github.com/PerkOS-xyz/Perkos-Containers" \
      perkos.runtime="hermes" \
      perkos.upstream-tag="${HERMES_TAG}"

# Defaults — overridable at runtime
ENV PERKOS_LLM_BASE_URL=https://api.llm.perkos.xyz/v1 \
    PERKOS_LLM_DEFAULT_MODEL=kimi-k2.6:cloud \
    HERMES_PROFILE_NAME=default

EXPOSE 8642

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8642/health >/dev/null || exit 1

ENTRYPOINT ["perkos-entrypoint.sh"]
CMD ["hermes-agent", "serve", "--profile", "default"]
