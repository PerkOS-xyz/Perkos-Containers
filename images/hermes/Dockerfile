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

ARG HERMES_TAG=latest
FROM nousresearch/hermes-agent:${HERMES_TAG}

ARG HERMES_TAG

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
COPY snapshot.sh /usr/local/bin/perkos-snapshot.sh
COPY restore.sh /usr/local/bin/perkos-restore.sh
RUN chmod 755 /usr/local/bin/perkos-snapshot.sh \
              /usr/local/bin/perkos-restore.sh

# s6-overlay hooks. cont-init.d runs at boot AFTER s6 sets up its
# environment (so s6-* binaries are in PATH) but BEFORE supervised
# services start. cont-finish.d runs at shutdown AFTER services
# have drained but BEFORE s6 exits. This replaces the deprecated
# perkos-entrypoint.sh: we used to be PID 1 + fork the upstream
# entrypoint, but upstream's /init now requires PID 1 (the suexec
# helper hard-fails otherwise). Hooks let us keep the same boot +
# shutdown behavior without owning PID 1.
COPY cont-init.d/01-perkos-boot.sh /etc/cont-init.d/01-perkos-boot.sh
COPY cont-finish.d/01-perkos-snapshot.sh /etc/cont-finish.d/01-perkos-snapshot.sh
RUN chmod 755 /etc/cont-init.d/01-perkos-boot.sh \
              /etc/cont-finish.d/01-perkos-snapshot.sh

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
      perkos.upstream-tag="${HERMES_TAG}"

# Prepend the upstream Hermes venv to PATH so legacy supervised
# services (the auto-generated per-profile `gateway` slots that
# hermes_cli.container_boot writes into /run/service/) can find
# `gateway`, `hermes`, and friends without each `run` script
# having to re-activate the venv. Upstream's main-wrapper.sh does
# `. /opt/hermes/.venv/bin/activate`, but the dynamic gateway
# services skip that step — so without this, s6-rc starts
# legacy-services, calls `gateway`, gets "command not found", and
# the container exits.
ENV PATH="/opt/hermes/.venv/bin:${PATH}"

# Defaults — overridable at runtime via -e.
ENV PERKOS_LLM_BASE_URL=https://api.llm.perkos.xyz/v1 \
    PERKOS_LLM_DEFAULT_MODEL=kimi-k2.6:cloud

# Match upstream's exact ENTRYPOINT pair: /init runs as PID 1 and
# /opt/hermes/docker/main-wrapper.sh is the "main program" /init
# launches once s6 finishes bringing up the supervision tree.
#
# Why both args (not just /init): main-wrapper.sh activates the
# venv (`. /opt/hermes/.venv/bin/activate`), routes argv to either
# `hermes <subcmd>`, a bare executable, or the default `hermes`
# binary, and drops privileges via s6-setuidgid. Without it, /init
# has no "main program" to run after stage2 — it tries to invoke
# whatever it can find on PATH and exits with "gateway: not
# found" once s6-rc's legacy-services bundle finishes setup.
#
# CMD stays empty (inherited from upstream); user-supplied args
# pass through main-wrapper.sh's routing logic:
#   docker run <image>                → defaults to `hermes`
#   docker run <image> chat -q "hi"   → `hermes chat -q "hi"`
#   docker run <image> sleep infinity → bare exec sleep
ENTRYPOINT ["/init", "/opt/hermes/docker/main-wrapper.sh"]
