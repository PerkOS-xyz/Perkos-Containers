# syntax=docker/dockerfile:1.7
#
# PerkOS-A2A bridge sidecar.
#
# Standalone Node process that runs alongside a Hermes (or OpenClaw)
# runtime container. Connects outbound to:
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
ARG PERKOS_A2A_VERSION=0.11.0

# tini for proper signal forwarding (perkos-a2a-agent doesn't handle
# SIGTERM gracefully without an init); ca-certificates because alpine
# ships a stripped bundle that some wss handshakes choke on.
RUN apk add --no-cache tini ca-certificates && \
    npm install -g @perkos/perkos-a2a@${PERKOS_A2A_VERSION}

LABEL org.opencontainers.image.title="PerkOS-A2A-Bridge" \
      org.opencontainers.image.description="Standalone perkos-a2a-agent bridge for Hermes/OpenClaw runtimes" \
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
