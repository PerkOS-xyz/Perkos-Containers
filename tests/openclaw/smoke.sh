#!/usr/bin/env bash
# Smoke test for the PerkOS-OpenClaw image.
#
# Runs the image twice in different modes:
#   1. Baseline boot with no gateway env  → plugin entries all disabled
#   2. Boot with TELEGRAM_ENABLED + SLACK_ENABLED set
#      → plugin entries true for those two, discord stays disabled
#      → the underlying TELEGRAM_BOT_TOKEN / SLACK_BOT_TOKEN env vars
#        are present in the container so the upstream plugins can
#        pick them up
#
# We don't actually exercise the upstream channel plugins (no real
# Telegram bot in CI); we only assert the rendered config has the
# correct enabled flags and the env passed through. That's enough
# to catch the most common regressions: a bad jq filter, a typo in
# the placeholder name, or the runtime env not propagating.
#
# Usage:
#   ./tests/openclaw/smoke.sh perkos-openclaw:test
#
# Exits 0 on pass, non-zero on the first failure.

set -uo pipefail

IMAGE="${1:-perkos-openclaw:test}"
TIMEOUT_BOOT_SECS=45

ok=0
fail() {
  echo "FAIL: $1" >&2
  if [ -n "${CONTAINER:-}" ]; then
    echo "--- last 30 log lines from $CONTAINER ---" >&2
    docker logs "$CONTAINER" 2>&1 | tail -30 >&2 || true
  fi
  ok=1
}
pass() {
  echo "OK: $1"
}

CONTAINER=""
cleanup() {
  if [ -n "$CONTAINER" ]; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

run_container() {
  # Args: name + extra -e env args.
  local name="$1"; shift
  CONTAINER="$name"
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker run -d --name "$CONTAINER" \
    -e PERKOS_AGENT_ID=smoke-test \
    -e PERKOS_AGENT_NAME=smoke-test \
    -e PERKOS_LLM_API_KEY=dummy-llm-key \
    -e PERKOS_LLM_BASE_URL=https://api.llm.perkos.xyz \
    -e PERKOS_LLM_DEFAULT_MODEL=kimi-k2.6:cloud \
    "$@" \
    "$IMAGE" >/dev/null

  # Wait for the entrypoint to render the config (max TIMEOUT_BOOT_SECS).
  local waited=0
  while [ "$waited" -lt "$TIMEOUT_BOOT_SECS" ]; do
    if docker exec "$CONTAINER" test -f /home/node/.openclaw/openclaw.json 2>/dev/null; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  fail "$name: config file never appeared at /home/node/.openclaw/openclaw.json"
  return 1
}

# ---------------------------------------------------------------
# Pass 1: baseline boot, no gateway env. All plugin entries off.
# ---------------------------------------------------------------
if run_container perkos-openclaw-smoke-baseline-$$; then
  if docker exec "$CONTAINER" sh -c 'jq -e ".plugins.entries.telegram.enabled == false" /home/node/.openclaw/openclaw.json' >/dev/null 2>&1; then
    pass "baseline: telegram disabled"
  else
    fail "baseline: telegram plugin entry should be enabled=false"
  fi
  if docker exec "$CONTAINER" sh -c 'jq -e ".plugins.entries.slack.enabled == false" /home/node/.openclaw/openclaw.json' >/dev/null 2>&1; then
    pass "baseline: slack disabled"
  else
    fail "baseline: slack plugin entry should be enabled=false"
  fi
  if docker exec "$CONTAINER" sh -c 'jq -e ".plugins.entries.discord.enabled == false" /home/node/.openclaw/openclaw.json' >/dev/null 2>&1; then
    pass "baseline: discord disabled"
  else
    fail "baseline: discord plugin entry should be enabled=false"
  fi
  # Make sure the existing perkos baseline still renders correctly.
  if docker exec "$CONTAINER" sh -c 'jq -e ".agent.id == \"smoke-test\"" /home/node/.openclaw/openclaw.json' >/dev/null 2>&1; then
    pass "baseline: agent.id rendered"
  else
    fail "baseline: agent.id missing or wrong"
  fi
  if docker exec "$CONTAINER" sh -c 'jq -e ".models.defaultModel == \"kimi-k2.6:cloud\"" /home/node/.openclaw/openclaw.json' >/dev/null 2>&1; then
    pass "baseline: defaultModel rendered"
  else
    fail "baseline: defaultModel missing or wrong"
  fi
fi

# ---------------------------------------------------------------
# Pass 2: Telegram + Slack enabled, Discord still disabled.
# ---------------------------------------------------------------
if run_container perkos-openclaw-smoke-gateways-$$ \
    -e TELEGRAM_ENABLED=true \
    -e TELEGRAM_BOT_TOKEN=fake-tg-token \
    -e SLACK_ENABLED=1 \
    -e SLACK_BOT_TOKEN=fake-slack-token \
    -e SLACK_SIGNING_SECRET=fake-signing-secret; then
  if docker exec "$CONTAINER" sh -c 'jq -e ".plugins.entries.telegram.enabled == true" /home/node/.openclaw/openclaw.json' >/dev/null 2>&1; then
    pass "gateways: telegram enabled"
  else
    fail "gateways: telegram plugin entry should be enabled=true"
  fi
  if docker exec "$CONTAINER" sh -c 'jq -e ".plugins.entries.slack.enabled == true" /home/node/.openclaw/openclaw.json' >/dev/null 2>&1; then
    pass "gateways: slack enabled (truthy=1 accepted)"
  else
    fail "gateways: slack plugin entry should be enabled=true (got 1 as truthy)"
  fi
  if docker exec "$CONTAINER" sh -c 'jq -e ".plugins.entries.discord.enabled == false" /home/node/.openclaw/openclaw.json' >/dev/null 2>&1; then
    pass "gateways: discord stays disabled when no DISCORD_ENABLED"
  else
    fail "gateways: discord should remain disabled"
  fi
  # The upstream channel plugins read the secret env vars directly,
  # not the config. Make sure those env vars made it into the
  # container's process env so the plugins can pick them up.
  if docker exec "$CONTAINER" sh -c 'test "$TELEGRAM_BOT_TOKEN" = fake-tg-token'; then
    pass "gateways: TELEGRAM_BOT_TOKEN propagated to process env"
  else
    fail "gateways: TELEGRAM_BOT_TOKEN missing from container env"
  fi
  if docker exec "$CONTAINER" sh -c 'test "$SLACK_BOT_TOKEN" = fake-slack-token'; then
    pass "gateways: SLACK_BOT_TOKEN propagated to process env"
  else
    fail "gateways: SLACK_BOT_TOKEN missing from container env"
  fi
fi

exit "$ok"
