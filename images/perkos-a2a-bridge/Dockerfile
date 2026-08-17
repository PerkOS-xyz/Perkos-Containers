# syntax=docker/dockerfile:1.7
#
# PerkOS-A2A bridge sidecar.
#
# Standalone Node process that runs alongside a Hermes/custom HTTP runtime
# container. OpenClaw uses the in-process plugin archive instead. Connects outbound to:
#   - wss://chat.perkos.xyz/chat        — user ↔ agent messages
#   - wss://transport.perkos.xyz/a2a    — agent ↔ agent tasks
# Authenticates with the agent's `relayApiKey` (issued at provision time).
# Forwards inbound chat/task frames to the local runtime over HTTP and
# pipes the runtime's replies back onto the wire.
#
# Pairs with images/hermes/ (or images/openclaw/) as a separate service
# in the same compose stack. The two containers share the compose network
# so the bridge can reach the runtime on its DNS name (e.g.
# http://perkos-assistant:8642 for Hermes).
#
# We pin @perkos/perkos-a2a to a specific version via build arg so CI
# can roll forward by bumping PERKOS_A2A_VERSION in the workflow env.

FROM node:22-alpine

# Default kept in lockstep with the workflow env's PERKOS_A2A_VERSION
# in .github/workflows/build-push-ecr.yml — bump them together.
# 0.12.57 routes ZeroClaw through the HTTP delivery path in every entry point;
# 0.12.56 reached only three of the four gates, so the agent connected and then
# failed every task.
# 0.12.56 delivers to the ZeroClaw runtime over POST /webhook, which takes a
# bare {"message": ...} and answers {"model", "response"}. ZeroClaw exposes no
# OpenAI-compatible route, so it cannot reuse the Hermes/OpenClaw body shapes.
# 0.12.50 adds authoritative organization/project/conversation context while
# keeping model selection owned by the external runtime.
# 0.12.49 reports execution-runtime health separately from bridge transport.
# 0.12.44 also recovers supervisor ownership after container PID reuse.
# 0.12.42 forwards the active OpenClaw runtime-owned route to legacy embedded
# chat runs without choosing an external agent's provider or model.
# 0.12.41 clears stale OpenClaw 2026.5 chat-session routing through the native
# session-store API while leaving provider/model selection runtime-owned.
# 0.12.39 keeps external model routing runtime-owned and fences stale OpenClaw
# hot-reload generations during certified supervisor rollover and rollback.
# 0.12.26 keeps external model routing runtime-owned and adds compatibility
# with OpenClaw gateways whose native harness is registered as `pi`.
# 0.12.25 makes external model routing runtime-owned for both the in-process
# OpenClaw path and the standalone Hermes/custom HTTP bridge.
# 0.12.22 keeps the platform heartbeat fresh while the bridge is alive and
# carries the current relay/chat workflow used by external invitations.
# 0.12.20 carries trusted MiniPay board context through shared fleet dispatch.
# 0.12.19 carries canonical project IDs and isolates OpenClaw chat sessions.
# 0.12.14 skips the Hermes/LLM turn for wallet-less auto-reply frames
# (agent-to-agent channel chatter that can never be routed a chat_reply) —
# saves a turn per such message on the shared fleet + drops the error-log noise.
# 0.12.13 carries the agent's SOUL to Hermes as request-level `instructions`
# (PERKOS_AGENT_SOUL_B64) so multi-agent co-residents reply in-persona even
# though the Hermes api_server platform isn't multiplex-aware.
ARG PERKOS_A2A_VERSION=0.12.57
ARG PERKOS_A2A_SHA256=094ddeb96051f22b125cc924c32cb2425d743f1b768457f690655f5df42df2f6

# tini for proper signal forwarding (perkos-a2a-agent doesn't handle
# SIGTERM gracefully without an init); ca-certificates because alpine
# ships a stripped bundle that some wss handshakes choke on.
RUN apk add --no-cache tini ca-certificates && \
    wget -q -O /tmp/perkos-a2a.tgz \
      "https://perkos.xyz/artifacts/perkos-a2a-${PERKOS_A2A_VERSION}.tgz" && \
    echo "${PERKOS_A2A_SHA256}  /tmp/perkos-a2a.tgz" | sha256sum -c - && \
    npm install -g /tmp/perkos-a2a.tgz && \
    rm /tmp/perkos-a2a.tgz

LABEL org.opencontainers.image.title="PerkOS-A2A-Bridge" \
      org.opencontainers.image.description="Standalone perkos-a2a-bridge for Hermes/custom HTTP runtimes" \
      org.opencontainers.image.source="https://github.com/PerkOS-xyz/Perkos-Containers" \
      perkos.runtime="bridge" \
      perkos.a2a-version="${PERKOS_A2A_VERSION}"

# Defaults — overridable at runtime via -e.
ENV A2A_PORT=5050 \
    A2A_BIND_HOST=0.0.0.0 \
    A2A_RELAY_ENABLED=true \
    A2A_RELAY_URL=wss://transport.perkos.xyz/a2a \
    A2A_CHAT_ENABLED=true \
    A2A_CHAT_URL=wss://chat.perkos.xyz/chat

EXPOSE 5050

ENTRYPOINT ["/sbin/tini", "-g", "--"]
# perkos-a2a-bridge (added in @perkos/perkos-a2a@0.9.2) is the
# chat-enabled standalone bridge. It runs A2AServer + ChatClient in
# one process; the older perkos-a2a-agent only handles the A2A
# protocol layer without chat. As of 0.10.0 the bridge also starts a
# local tools-token HTTP listener (when A2A_TOOLS_API_URL +
# A2A_TOOLS_JWT_SECRET are set) so the runtime plugin can mint
# short-lived JWTs for Platform-Tools-API calls.
CMD ["perkos-a2a-bridge"]
