#!/usr/bin/env bash
# Smoke test for the PerkOS-OpenClaw image.
#
# Asserts the entrypoint renders config/openclaw.template.json into
# $OPENCLAW_CONFIG_PATH with the env-var placeholders substituted, and
# that the PerkOS persona (PERKOS_AGENT_SOUL_B64) is written to the
# workspace as AGENTS.md when provided.
#
# We assert against the *current* OpenClaw config schema
# (agents.defaults.model.primary, gateway.auth.token,
# models.providers.ollama.*). The template has no channel-plugin block
# anymore, so there are no telegram/slack/discord assertions — channel
# secrets are still checked for env pass-through since the upstream
# plugins read them directly from the process env.
#
# Usage:
#   ./tests/openclaw/smoke.sh perkos-openclaw:test
#
# Exits 0 on pass, non-zero on the first failure.

set -uo pipefail

IMAGE="${1:-perkos-openclaw:test}"
TIMEOUT_BOOT_SECS=45
CFG=/home/node/.openclaw/openclaw.json
AGENTS_MD=/home/node/.openclaw/workspace/AGENTS.md

ok=0
fail() {
  echo "FAIL: $1" >&2
  if [ -n "${CONTAINER:-}" ]; then
    echo "--- last 30 log lines from $CONTAINER ---" >&2
    docker logs "$CONTAINER" 2>&1 | tail -30 >&2 || true
  fi
  ok=1
}
pass() { echo "OK: $1"; }

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
    if docker exec "$CONTAINER" test -f "$CFG" 2>/dev/null; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  fail "$name: config file never appeared at $CFG"
  return 1
}

jqok() {
  # jqok "<description>" '<jq filter that should be truthy>'
  if docker exec "$CONTAINER" sh -c "jq -e '$2' $CFG" >/dev/null 2>&1; then
    pass "$1"
  else
    fail "$1"
  fi
}

# ---------------------------------------------------------------
# Pass 1: baseline boot. Assert the current schema renders with the
# env-var substitutions applied.
# ---------------------------------------------------------------
if run_container perkos-openclaw-smoke-baseline-$$; then
  jqok "baseline: config is valid JSON object"          'type == "object"'
  jqok "baseline: model.primary substituted"            '.agents.defaults.model.primary == "ollama/kimi-k2.6:cloud"'
  jqok "baseline: gateway is local + token-auth"        '.gateway.mode == "local" and .gateway.auth.mode == "token"'
  jqok "baseline: gateway token substituted (non-empty, no placeholder)" \
       '(.gateway.auth.token | type == "string" and length > 0 and (startswith("__") | not))'
  jqok "baseline: ollama baseUrl substituted"           '.models.providers.ollama.baseUrl == "https://api.llm.perkos.xyz"'
  jqok "baseline: ollama apiKey substituted"            '.models.providers.ollama.apiKey == "dummy-llm-key"'
  jqok "baseline: agent id header substituted"          '.models.providers.ollama.headers["x-agent-id"] == "smoke-test"'
  jqok "baseline: no unsubstituted __PLACEHOLDER__ left" \
       '[.. | strings | select(startswith("__") and endswith("__"))] | length == 0'

  # Persona must NOT be written when the env var is absent.
  if docker exec "$CONTAINER" test -f "$AGENTS_MD" 2>/dev/null; then
    fail "baseline: AGENTS.md should NOT exist without PERKOS_AGENT_SOUL_B64"
  else
    pass "baseline: no AGENTS.md without persona env (correct)"
  fi
fi

# ---------------------------------------------------------------
# Pass 2: persona injection. PERKOS_AGENT_SOUL_B64 (base64 markdown)
# must be decoded to the workspace as AGENTS.md.
# ---------------------------------------------------------------
SOUL_PLAIN='# Smoke Persona
You are the smoke-test agent. Marker: PERKOS_SOUL_SMOKE_OK.'
SOUL_B64="$(printf '%s' "$SOUL_PLAIN" | base64 | tr -d '\n')"

if run_container perkos-openclaw-smoke-soul-$$ -e PERKOS_AGENT_SOUL_B64="$SOUL_B64"; then
  # Give the entrypoint a moment to write AGENTS.md after the config.
  waited=0
  while [ "$waited" -lt 10 ]; do
    docker exec "$CONTAINER" test -f "$AGENTS_MD" 2>/dev/null && break
    sleep 1; waited=$((waited + 1))
  done
  if docker exec "$CONTAINER" test -f "$AGENTS_MD" 2>/dev/null; then
    pass "soul: AGENTS.md written from PERKOS_AGENT_SOUL_B64"
  else
    fail "soul: AGENTS.md missing despite PERKOS_AGENT_SOUL_B64"
  fi
  if docker exec "$CONTAINER" sh -c "grep -q PERKOS_SOUL_SMOKE_OK $AGENTS_MD" 2>/dev/null; then
    pass "soul: AGENTS.md content decoded correctly"
  else
    fail "soul: AGENTS.md content marker not found (bad base64 decode?)"
  fi
fi

# ---------------------------------------------------------------
# Pass 3: channel secrets propagate to the process env. The upstream
# plugins read these directly; the entrypoint must not strip them.
# ---------------------------------------------------------------
if run_container perkos-openclaw-smoke-env-$$ \
    -e TELEGRAM_BOT_TOKEN=fake-tg-token \
    -e SLACK_BOT_TOKEN=fake-slack-token; then
  if docker exec "$CONTAINER" sh -c 'test "$TELEGRAM_BOT_TOKEN" = fake-tg-token'; then
    pass "env: TELEGRAM_BOT_TOKEN propagated to process env"
  else
    fail "env: TELEGRAM_BOT_TOKEN missing from container env"
  fi
  if docker exec "$CONTAINER" sh -c 'test "$SLACK_BOT_TOKEN" = fake-slack-token'; then
    pass "env: SLACK_BOT_TOKEN propagated to process env"
  else
    fail "env: SLACK_BOT_TOKEN missing from container env"
  fi
fi

exit "$ok"
