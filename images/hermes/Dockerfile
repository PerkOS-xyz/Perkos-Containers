# syntax=docker/dockerfile:1.7
#
# Hermes + PerkOS wrapper.
#
# Layers on top of the official nousresearch/hermes-agent image:
#   1. Renders /opt/data/config.yaml from PERKOS_* env vars at boot
#   2. Bakes the PerkOS Assistant content (SOUL + runbook) into the image
#   3. Bakes the perkos-platform-tools skill (documentation-only at v1)
#   4. Delegates the actual `hermes` start to upstream's entrypoint, which
#      drops to the `hermes` user, sources the venv, and execs `hermes`
#
# Upstream invariants we now respect (broke in v1, fixed here):
#   - HERMES_HOME = /opt/data (NOT /root/.hermes)
#   - Binary is `hermes` at /opt/hermes/.venv/bin/hermes (NOT `hermes-agent`)
#   - Skills auto-discovered from $HERMES_HOME/skills/
#   - Upstream entrypoint /opt/hermes/docker/entrypoint.sh does user-drop +
#     venv activation; we delegate to it instead of replacing it
#
# The perkos-a2a bridge (chat.perkos.xyz + transport.perkos.xyz) is a
# separate sidecar process — npm package @perkos/perkos-a2a, runs via
# `perkos-a2a-agent` CLI. NOT bundled into this image; the compose file
# at deploy/perkos-assistant/ adds it as its own service (follow-up PR).

# HERMES_REF is the full base reference. Locally it defaults to the moving
# `:latest` tag; CI resolves `:latest` to a concrete @sha256 digest and
# passes it here so each weekly release is reproducible. HERMES_TAG /
# HERMES_VERSION stay around purely for the human-readable labels.
ARG HERMES_REF=nousresearch/hermes-agent:latest
FROM ${HERMES_REF}

ARG HERMES_TAG=latest
ARG HERMES_REF=nousresearch/hermes-agent:latest
ARG HERMES_VERSION=

USER root

# envsubst + ca-certs for HTTPS to the model providers, plus the AWS
# CLI for hibernation snapshot/restore to S3. awscli pulls in ~30 MB
# of Python deps but avoids us having to ship boto3 separately in the
# venv — the snapshot/restore scripts are bash, so the CLI fits.
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      gettext-base ca-certificates awscli && \
    rm -rf /var/lib/apt/lists/*

COPY config/hermes.template.yaml /opt/perkos/hermes.template.yaml
COPY docker-entrypoint.sh /usr/local/bin/perkos-entrypoint.sh
COPY snapshot.sh /usr/local/bin/perkos-snapshot.sh
COPY restore.sh /usr/local/bin/perkos-restore.sh
COPY perkos-render-profiles.py /usr/local/bin/perkos-render-profiles.py
RUN chmod 755 /usr/local/bin/perkos-entrypoint.sh \
              /usr/local/bin/perkos-snapshot.sh \
              /usr/local/bin/perkos-restore.sh \
              /usr/local/bin/perkos-render-profiles.py

# PerkOS Assistant content — SOUL (persona) + runbook (FAQ knowledge).
# Used only when the container is provisioned as the platform identity
# "PerkOS-Assistant". Regular user-launched agents ignore this dir; baking
# the ~50 KB of markdown into every image keeps the deploy uniform.
COPY perkos-assistant /opt/perkos-assistant

# perkos-platform-tools Hermes skill — documentation-only at v1. Hermes
# auto-discovers skills under $HERMES_HOME/skills/ at startup. The
# upstream entrypoint creates $HERMES_HOME/skills/ as the hermes user;
# we copy our skill in with permissive ownership so the user can read it.
COPY skills/perkos-platform-tools /opt/perkos-skills/perkos-platform-tools
# The actual symlink/copy into $HERMES_HOME/skills/ happens in
# perkos-entrypoint.sh after upstream has set up HERMES_HOME with the
# right ownership.

# perkos-knowledge (PerkOS Knowledge) — NATIVE Hermes plugin (kind: standalone).
# Exposes perkos_knowledge_* as first-class Hermes tools (query/manifest/x402
# + the provider request loop). Staged into $HERMES_HOME/plugins/ at boot and
# enabled via config.yaml `plugins.enabled`. Stdlib-only (no extra deps).
COPY plugins/perkos-knowledge /opt/perkos-plugins/perkos-knowledge

# Hermes PLATFORM plugins — gateway adapters that bring in inbound
# messages from external services (Telegram, Slack, Farcaster...).
# Different from skills: platforms live under plugins/platforms/,
# loaded by Hermes's PlatformRegistry. Each one is a self-contained
# Python module with plugin.yaml + src/ + tests/. The entrypoint
# stages them into $HERMES_HOME/plugins/platforms/ at boot, matching
# the directory Hermes scans on startup.
COPY plugins/platforms/farcaster /opt/perkos-platforms/farcaster

LABEL org.opencontainers.image.title="PerkOS-Hermes" \
      org.opencontainers.image.description="Hermes agent + PerkOS LLM provider + Assistant content baked in" \
      org.opencontainers.image.source="https://github.com/PerkOS-xyz/Perkos-Containers" \
      perkos.runtime="hermes" \
      perkos.upstream-tag="${HERMES_TAG}" \
      perkos.upstream-ref="${HERMES_REF}" \
      perkos.upstream-version="${HERMES_VERSION}"

# Defense in depth — prepend the upstream Hermes venv to PATH so any
# subprocess that doesn't activate the venv first (e.g. ad-hoc
# `docker exec` runs of `hermes`) still finds the binary. The
# upstream entrypoint script also sets this, but having it baked in
# at the image level means it's still present in our environment if
# the upstream path-handling drifts.
ENV PATH="/opt/hermes/.venv/bin:${PATH}"

# Defaults — overridable at runtime via -e.
ENV PERKOS_LLM_BASE_URL=https://api.llm.perkos.xyz/v1 \
    PERKOS_LLM_DEFAULT_MODEL=kimi-k2.6:cloud

# Our entrypoint runs FIRST (renders config, copies skill + platform
# plugin into HERMES_HOME), then forks upstream's docker/entrypoint.sh
# as a child so we keep PID 1 — that's how the SIGTERM trap survives
# long enough to snapshot. On graceful shutdown we forward TERM to
# upstream, wait for it to drain, then snapshot HERMES_HOME to S3
# (no-op when PERKOS_HIBERNATION_S3_URI is unset).
ENTRYPOINT ["perkos-entrypoint.sh"]
# No CMD — upstream's entrypoint inherits its own CMD via exec. Override
# at compose level (e.g. `command: ["gateway", "run"]`) for the
# long-lived gateway daemon used by PerkOS-Assistant.
