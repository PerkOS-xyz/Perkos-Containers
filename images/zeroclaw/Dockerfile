# syntax=docker/dockerfile:1.7
#
# ZeroClaw + PerkOS wrapper.
#
# Layers on top of the official ZeroClaw image — not a fork, same contract as
# images/openclaw and images/hermes: bump the tag to chase upstream.
#
# WHY `:debian` AND NOT `:latest` — upstream's `:latest` is DISTROLESS
# (gcr.io/distroless/cc-debian13:nonroot): no shell, no package manager. Every
# PerkOS boot contract we rely on (bash entrypoint, awscli hibernation
# snapshot/restore, the hardened skill fetch) is impossible there. `:debian` is
# the same binary on a Debian base, published multi-arch (amd64 + arm64), and is
# the only variant that can carry the platform contract. `:alpine` exists in the
# upstream tree but is NOT published to GHCR.
#
# What we add:
#   1. An entrypoint that renders ~/.zeroclaw/config.toml from PERKOS_* env by
#      DRIVING THE BINARY (`zeroclaw config set --no-interactive`) rather than
#      writing TOML by hand, so upstream owns schema validation + secret
#      encryption (secrets land as `enc2:…`, never plaintext).
#   2. A pre-seeded gateway token so provisioning is non-interactive (upstream
#      otherwise demands an interactive pairing code).
#   3. The shared hibernation snapshot/restore scripts.
#   4. The bundled PerkOS skills.
#
# The perkos-a2a bridge runs as a separate container in the ECS task, exactly
# like the other two runtimes. NOTE: ZeroClaw's gateway does NOT expose an
# OpenAI-compatible /v1/chat/completions (POST returns 405 — the third-party
# docs are wrong). Delivery is `POST /webhook {"message": "..."}` with a Bearer
# token, answering `{"model": "...", "response": "..."}`. The bridge needs its
# own zeroclaw adapter; it cannot reuse the OpenClaw/Hermes delivery path.

ARG ZEROCLAW_REF=ghcr.io/zeroclaw-labs/zeroclaw:debian
FROM ${ZEROCLAW_REF}

# Re-declare so they're available in the runtime stage (for labels).
ARG ZEROCLAW_TAG=debian
ARG ZEROCLAW_REF=ghcr.io/zeroclaw-labs/zeroclaw:debian
ARG ZEROCLAW_VERSION=

USER root

# bash + jq drive the entrypoint; the AWS CLI + openssl back the hibernation
# snapshot/restore scripts (client-side encrypted state backup to S3), matching
# what images/openclaw and images/hermes install.
#
# python3 is NOT optional here. The other two images get an interpreter for free
# from their base (Hermes is Python, OpenClaw is Node) and use it for the
# hardened skill-pack fetch. ZeroClaw is a single Rust binary on a bare Debian,
# so without this the skill fetch would silently no-op in production. curl backs
# the container healthcheck path used by the smoke test.
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash jq ca-certificates openssl awscli curl python3 && \
    rm -rf /var/lib/apt/lists/*

COPY docker-entrypoint.sh /usr/local/bin/perkos-entrypoint.sh
# Hibernation snapshot/restore (shared with the other two images; only the
# per-runtime exclude list differs).
COPY snapshot.sh /usr/local/bin/perkos-snapshot.sh
COPY restore.sh /usr/local/bin/perkos-restore.sh
RUN chmod 755 /usr/local/bin/perkos-entrypoint.sh \
              /usr/local/bin/perkos-snapshot.sh \
              /usr/local/bin/perkos-restore.sh

# Bundled PerkOS skills (SKILL.md format — ZeroClaw reads the same shape as
# OpenClaw). Staged into the agent's skills dir at boot by the entrypoint.
COPY skills /opt/perkos-skills

LABEL org.opencontainers.image.title="PerkOS-ZeroClaw" \
      org.opencontainers.image.description="ZeroClaw with PerkOS-LLM provider + ECS-ready config" \
      org.opencontainers.image.source="https://github.com/PerkOS-xyz/Perkos-Containers" \
      perkos.runtime="zeroclaw" \
      perkos.upstream-tag="${ZEROCLAW_TAG}" \
      perkos.upstream-ref="${ZEROCLAW_REF}" \
      perkos.upstream-version="${ZEROCLAW_VERSION}"

# HOME is where ZeroClaw looks for .zeroclaw/config.toml. Upstream already sets
# it to /zeroclaw-data; make sure the unprivileged runtime user owns the tree,
# otherwise the very first `config set` fails on a read-only dir.
RUN mkdir -p /zeroclaw-data && chown -R 65534:65534 /zeroclaw-data /opt/perkos-skills

USER 65534

# Defaults — overridable at runtime via -e.
# PERKOS_LLM_BASE_URL is the endpoint the client hits. ZeroClaw's provider block
# calls this `uri` (NOT `base_url`), and the /v1 root is what our gateway serves.
ENV PERKOS_LLM_BASE_URL=https://api.llm.perkos.xyz/v1 \
    PERKOS_LLM_DEFAULT_MODEL=kimi-k2.6:cloud \
    PERKOS_ZEROCLAW_AGENT_ALIAS=default \
    ZEROCLAW_GATEWAY_PORT=42617 \
    HOME=/zeroclaw-data

EXPOSE 42617

# Upstream's own status probe — exec-based, so it works without a shell HTTP
# client and reports the daemon's view rather than just a bound socket.
HEALTHCHECK --interval=30s --timeout=10s --start-period=45s --retries=3 \
  CMD ["zeroclaw", "status", "--format=exit-code"]

ENTRYPOINT ["perkos-entrypoint.sh"]
CMD ["gateway", "start"]
