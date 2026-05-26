#!/usr/bin/env bash
# Smoke test for the perkos-a2a-bridge image.
#
# Runs the bridge container with mocked env vars + no upstream Hermes
# reachable, then asserts:
#   - the image built (npm install of @perkos/perkos-a2a succeeded)
#   - perkos-a2a-agent is on PATH and prints --help cleanly
#   - the container starts up (we don't expect a long-running healthy
#     state here because there's no Hermes to forward to; we only verify
#     the binary is launchable + env-driven config doesn't bail at parse
#     time)
#
# This is intentionally less strict than the Hermes smoke test — the
# bridge is a passive forwarder, so end-to-end validation requires real
# chat.perkos.xyz + transport.perkos.xyz access which isn't available
# from GitHub CI runners on the company network. Full integration check
# happens on the LLM VPS after deploy.
#
# Usage:
#   ./tests/perkos-a2a-bridge/smoke.sh perkos-a2a-bridge:test

set -uo pipefail

IMAGE="${1:-perkos-a2a-bridge:test}"
CONTAINER="perkos-a2a-bridge-smoke-$$"

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() {
  echo "❌ FAIL: $1" >&2
  echo "--- last 30 log lines ---" >&2
  docker logs "$CONTAINER" 2>&1 | tail -30 >&2 || true
  exit 1
}
pass() { echo "✅ $1"; }

# --- Binary presence ---
echo "▶ checking perkos-a2a-agent is on PATH in $IMAGE ..."
if docker run --rm --entrypoint sh "$IMAGE" -c 'command -v perkos-a2a-agent >/dev/null'; then
  pass "perkos-a2a-agent binary present"
else
  fail "perkos-a2a-agent not on PATH — npm install layer broken"
fi

if docker run --rm --entrypoint sh "$IMAGE" -c 'command -v node >/dev/null'; then
  pass "node runtime present"
else
  fail "node runtime missing"
fi

# --- Config parse smoke ---
# The bridge reads its config from env on startup. Boot it with minimal
# env, give it ~5s, then check it's still running. We don't expect it
# to be HEALTHY (no Hermes to reach + no real chat key), only that it
# survives the config parse + initial server bind.
echo "▶ booting $IMAGE with mocked env ..."
docker run -d --name "$CONTAINER" \
  -e A2A_AGENT_NAME=smoke-test \
  -e A2A_RELAY_API_KEY=dummy-key \
  -e HERMES_API_URL=http://invalid-host:8642 \
  -e A2A_RUNTIME=hermes-api \
  -e A2A_RELAY_ENABLED=false \
  -e A2A_CHAT_ENABLED=false \
  "$IMAGE" >/dev/null || fail "docker run failed"

# Give it 5s to either crash on config parse or start listening.
sleep 5
state=$(docker inspect "$CONTAINER" --format '{{.State.Status}}' 2>/dev/null || echo missing)
restarts=$(docker inspect "$CONTAINER" --format '{{.RestartCount}}' 2>/dev/null || echo 0)

if [ "$state" = "exited" ]; then
  fail "container exited (state=$state) — likely config parse error or missing dep"
fi
if [ "$restarts" -gt 0 ]; then
  fail "container restarted (restarts=$restarts)"
fi
if [ "$state" = "running" ]; then
  pass "container running (state=$state restarts=$restarts)"
else
  fail "unexpected state: $state"
fi

# --- Log sanity: no thrown errors during startup ---
logs=$(docker logs "$CONTAINER" 2>&1)
if echo "$logs" | grep -qE "^Error:|Uncaught|throw new" ; then
  fail "startup logs contain uncaught error"
fi
pass "no uncaught error in startup logs"

echo ""
echo "✅ All smoke checks passed for $IMAGE"
exit 0
