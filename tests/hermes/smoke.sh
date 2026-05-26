#!/usr/bin/env bash
# Smoke test for the PerkOS-Hermes image.
#
# Runs the image with mocked env vars, waits for it to become healthy,
# then asserts:
#   - container is running and not restarting
#   - upstream entrypoint chain was reached (logs contain "Hermes Gateway Starting")
#   - no "Permission denied" errors on skill install
#   - perkos-platform-tools skill landed at $HERMES_HOME/skills/
#   - PerkOS Assistant content is present at /opt/perkos-assistant/
#   - the rendered config.yaml has the expected fields
#
# Usage:
#   ./tests/hermes/smoke.sh perkos-hermes:test
#
# Designed to run in CI after `docker buildx build --load -t <image>`
# and locally with the same. Exits 0 on pass, non-zero on any failure.

set -uo pipefail

IMAGE="${1:-perkos-hermes:test}"
CONTAINER="perkos-hermes-smoke-$$"
TIMEOUT_BOOT_SECS=60

# Mock env — values are dummies; smoke test only verifies the container
# stays up, not that it can actually reach chat.perkos.xyz.
ENV_ARGS=(
  -e PERKOS_AGENT_ID=smoke-test
  -e PERKOS_AGENT_NAME=smoke-test
  -e PERKOS_LLM_API_KEY=dummy
  -e PERKOS_LLM_BASE_URL=https://api.llm.perkos.xyz/v1
  -e PERKOS_LLM_DEFAULT_MODEL=kimi-k2.6:cloud
)

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() {
  echo "❌ FAIL: $1" >&2
  echo "--- last 50 log lines ---" >&2
  docker logs "$CONTAINER" 2>&1 | tail -50 >&2 || true
  exit 1
}

pass() {
  echo "✅ $1"
}

echo "▶ booting $IMAGE as $CONTAINER ..."
docker run -d --name "$CONTAINER" "${ENV_ARGS[@]}" "$IMAGE" gateway run >/dev/null \
  || fail "docker run failed"

# Wait for container to either become healthy OR settle into a stable
# "running" state (with the process-check healthcheck this takes up to
# start_period=60s). If it's restarting at any point during the window,
# fail fast — restart loops are the v1 regression we're guarding against.
echo "▶ waiting up to ${TIMEOUT_BOOT_SECS}s for stability ..."
DEADLINE=$(( $(date +%s) + TIMEOUT_BOOT_SECS ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  state=$(docker inspect "$CONTAINER" --format '{{.State.Status}}' 2>/dev/null || echo missing)
  restarts=$(docker inspect "$CONTAINER" --format '{{.RestartCount}}' 2>/dev/null || echo 0)
  if [ "$state" = "exited" ]; then
    fail "container exited (state=$state restarts=$restarts)"
  fi
  if [ "$restarts" -gt 0 ]; then
    fail "container restarted (restarts=$restarts) — restart loop regression"
  fi
  # Stable + a few seconds for upstream entrypoint to finish bundled-skill
  # install is enough to start asserting.
  uptime=$(docker inspect "$CONTAINER" --format '{{.State.StartedAt}}' 2>/dev/null)
  if [ "$state" = "running" ]; then
    age=$(( $(date +%s) - $(date -d "$uptime" +%s 2>/dev/null || echo $(date +%s)) ))
    if [ "$age" -ge 20 ]; then
      pass "container stable for ${age}s (state=$state restarts=$restarts)"
      break
    fi
  fi
  sleep 2
done

if [ "$state" != "running" ]; then
  fail "container never reached stable running state (last state=$state)"
fi

# --- Log assertions ---
logs=$(docker logs "$CONTAINER" 2>&1)

if echo "$logs" | grep -q "Permission denied"; then
  fail "logs contain 'Permission denied' — upstream skill install was blocked by file perms"
fi
pass "no 'Permission denied' errors in logs"

if echo "$logs" | grep -q "perkos-entrypoint: wrote /opt/data/config.yaml"; then
  pass "our entrypoint rendered the config"
else
  fail "our entrypoint never wrote /opt/data/config.yaml — exec chain broken"
fi

if echo "$logs" | grep -q "Hermes Gateway Starting"; then
  pass "upstream Hermes gateway reached startup banner"
else
  fail "upstream Hermes never reached 'Hermes Gateway Starting' — delegation broken"
fi

# --- File-presence assertions (via docker exec) ---
if docker exec "$CONTAINER" test -f /opt/data/config.yaml; then
  pass "config.yaml exists at /opt/data/config.yaml"
else
  fail "/opt/data/config.yaml missing"
fi

if docker exec "$CONTAINER" test -d /opt/data/skills/perkos-platform-tools; then
  pass "perkos-platform-tools skill installed at /opt/data/skills/"
else
  fail "/opt/data/skills/perkos-platform-tools missing — skill copy failed"
fi

if docker exec "$CONTAINER" test -f /opt/data/skills/perkos-platform-tools/SKILL.md; then
  pass "SKILL.md present in installed skill"
else
  fail "SKILL.md missing from installed skill"
fi

if docker exec "$CONTAINER" test -x /opt/data/skills/perkos-platform-tools/scripts/perkos_tools.py; then
  pass "perkos_tools.py executable in installed skill"
else
  fail "perkos_tools.py missing or not executable"
fi

if docker exec "$CONTAINER" python3 /opt/data/skills/perkos-platform-tools/scripts/perkos_tools.py --help >/dev/null 2>&1; then
  pass "perkos_tools.py --help runs under python3"
else
  fail "perkos_tools.py --help failed under container's python3"
fi

if docker exec "$CONTAINER" test -f /opt/data/skills/perkos-platform-tools/references/examples.md; then
  pass "references/examples.md baked into installed skill"
else
  fail "references/examples.md missing from installed skill"
fi

# Hibernation snapshot/restore scripts are in place.
if docker exec "$CONTAINER" test -x /usr/local/bin/perkos-snapshot.sh; then
  pass "perkos-snapshot.sh installed + executable"
else
  fail "perkos-snapshot.sh missing or not executable"
fi
if docker exec "$CONTAINER" test -x /usr/local/bin/perkos-restore.sh; then
  pass "perkos-restore.sh installed + executable"
else
  fail "perkos-restore.sh missing or not executable"
fi

# Confirm aws-cli is on PATH (snapshot/restore need it).
if docker exec "$CONTAINER" aws --version >/dev/null 2>&1; then
  pass "aws CLI present (hibernation can call S3)"
else
  fail "aws CLI missing — hibernation snapshot/restore will fail at runtime"
fi

# No-op contract: with no S3 URI env, snapshot must skip cleanly.
if docker exec "$CONTAINER" sh -c \
    "env -u PERKOS_HIBERNATION_S3_URI HERMES_HOME=/opt/data /usr/local/bin/perkos-snapshot.sh 2>/dev/null" \
    | grep -q '"skipped": true'; then
  pass "snapshot.sh no-op when PERKOS_HIBERNATION_S3_URI unset"
else
  fail "snapshot.sh should skip with JSON status when S3 URI is unset"
fi

# Confirm the script fails fast (exit 4) when the bridge auth env var is
# absent — the contract our SKILL.md promises to the LLM.
if docker exec "$CONTAINER" sh -c "unset A2A_BRIDGE_AUTH_SECRET PERKOS_CONV_ID; python3 /opt/data/skills/perkos-platform-tools/scripts/perkos_tools.py call listMyAgents '{}' --conv-id smoke 2>&1; echo exit=\$?" | grep -q "exit=4"; then
  pass "perkos_tools.py fails fast (exit 4) without A2A_BRIDGE_AUTH_SECRET"
else
  fail "perkos_tools.py did not exit 4 when bridge auth missing — env contract broken"
fi

if docker exec "$CONTAINER" test -f /opt/perkos-assistant/SOUL.md; then
  pass "Assistant SOUL.md baked into image"
else
  fail "/opt/perkos-assistant/SOUL.md missing"
fi

if docker exec "$CONTAINER" sh -c 'ls /opt/perkos-assistant/runbook/ 2>/dev/null | wc -l' | grep -qE '^[1-9]'; then
  pass "Assistant runbook/ has entries"
else
  fail "/opt/perkos-assistant/runbook/ empty or missing"
fi

# --- Config sanity ---
config=$(docker exec "$CONTAINER" cat /opt/data/config.yaml 2>/dev/null)
if echo "$config" | grep -q "provider: custom"; then
  pass "config.yaml has provider: custom"
else
  fail "config.yaml missing 'provider: custom' (was env substitution applied?)"
fi
if echo "$config" | grep -q "api_key_env: PERKOS_LLM_API_KEY"; then
  pass "config.yaml has api_key_env: PERKOS_LLM_API_KEY"
else
  fail "config.yaml missing api_key_env binding"
fi

echo ""
echo "✅ All smoke checks passed for $IMAGE"
exit 0
