#!/usr/bin/env bash
# Smoke test for the PerkOS-ZeroClaw image.
#
# Asserts the entrypoint renders ~/.zeroclaw/config.toml by driving
# `zeroclaw config set --no-interactive`, that the provider/agent/risk-profile
# wiring is complete, that the persona lands as an OpenClaw-format identity
# file, and that the gateway boots ALREADY PAIRED with our minted bearer.
#
# The pairing and risk-profile assertions are the ones that matter: without a
# pre-seeded gateway.paired_tokens the runtime demands an interactive pairing
# code (unusable in ECS), and without a configured risk_profiles entry every
# message fails with a misleading `500 {"error":"LLM request failed"}` while the
# LLM is never called.
#
# Usage:
#   ./tests/zeroclaw/smoke.sh perkos-zeroclaw:test
#
# Exits 0 on pass, non-zero on the first failure.

set -uo pipefail

IMAGE="${1:-perkos-zeroclaw:test}"
TIMEOUT_BOOT_SECS=60
ZC_HOME=/zeroclaw-data
CFG="$ZC_HOME/.zeroclaw/config.toml"
TOKEN=zcl_live_smoketest0000000000000000000000000000

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

imageok() {
  if eval "$2" >/dev/null 2>&1; then
    pass "$1"
  else
    fail "$1"
  fi
}

CONTAINER=""
cleanup() {
  if [ -n "$CONTAINER" ]; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# ── Image metadata ───────────────────────────────────────────────────────────
imageok "image: exposes ZeroClaw gateway port 42617" \
  "docker image inspect '$IMAGE' --format '{{json .Config.ExposedPorts}}' | jq -e 'has(\"42617/tcp\")'"
imageok "image: labelled as the zeroclaw runtime" \
  "docker image inspect '$IMAGE' --format '{{index .Config.Labels \"perkos.runtime\"}}' | grep -qx zeroclaw"
imageok "image: hibernation scripts are baked and executable" \
  "docker run --rm --entrypoint sh '$IMAGE' -c 'test -x /usr/local/bin/perkos-snapshot.sh && test -x /usr/local/bin/perkos-restore.sh'"
imageok "image: AWS CLI present (hibernation upload path)" \
  "docker run --rm --entrypoint sh '$IMAGE' -c 'command -v aws'"
imageok "image: bundled perkos-platform-tools skill is baked" \
  "docker run --rm --entrypoint sh '$IMAGE' -c 'test -f /opt/perkos-skills/perkos-platform-tools/SKILL.md'"

# ── Boot ─────────────────────────────────────────────────────────────────────
SOUL_B64="$(printf '# Smoke Persona\n\nYou are the PerkOS smoke-test agent.\n' | base64 | tr -d '\n')"

CONTAINER=perkos-zeroclaw-smoke
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" \
  -e PERKOS_AGENT_ID=smoke-test \
  -e PERKOS_AGENT_NAME=smoke-test \
  -e PERKOS_LLM_API_KEY=dummy-llm-key \
  -e PERKOS_LLM_DEFAULT_MODEL=kimi-k2.6:cloud \
  -e PERKOS_GATEWAY_API_KEY="$TOKEN" \
  -e PERKOS_AGENT_SOUL_B64="$SOUL_B64" \
  "$IMAGE" >/dev/null 2>&1

# Wait for the gateway to answer its unauthenticated health route.
booted=0
for _ in $(seq 1 "$TIMEOUT_BOOT_SECS"); do
  if docker exec "$CONTAINER" curl -fsS -m 3 http://127.0.0.1:42617/health >/dev/null 2>&1; then
    booted=1
    break
  fi
  sleep 1
done
if [ "$booted" = "1" ]; then
  pass "gateway: /health answers within ${TIMEOUT_BOOT_SECS}s"
else
  fail "gateway: /health never answered within ${TIMEOUT_BOOT_SECS}s"
fi

cfgok() { # description, grep-pattern
  if docker exec "$CONTAINER" grep -qE "$2" "$CFG" 2>/dev/null; then
    pass "$1"
  else
    fail "$1 (pattern: $2)"
  fi
}

# ── Rendered config ──────────────────────────────────────────────────────────
cfgok "config: provider uri points at the PerkOS LLM gateway" \
  '^uri = "https://api\.llm\.perkos\.xyz/v1"'
cfgok "config: provider model rendered from env" \
  '^model = "kimi-k2\.6:cloud"'
cfgok "config: openai-compatible wire protocol selected" \
  '^wire_api = "chat_completions"'
cfgok "config: provider implementation is openai-compatible" \
  '^kind = "openai-compatible"'
# The LLM key must never be readable in the rendered config: ZeroClaw encrypts
# secrets at rest and we depend on that.
cfgok "config: LLM api_key stored encrypted (enc2:)" \
  '^api_key = "enc2:'
if docker exec "$CONTAINER" grep -q 'dummy-llm-key' "$CFG" 2>/dev/null; then
  fail "config: LLM key leaked in plaintext into config.toml"
else
  pass "config: LLM key is not present in plaintext"
fi
cfgok "config: agent bound to the custom.perkos provider" \
  '^model_provider = "custom\.perkos"'
# Regression guard: the gateway dispatches /webhook to the baked `default`
# agent. Configuring some other alias yields a container that boots healthy,
# passes a provider health check, and still fails every message.
imageok "config: the ROUTED default agent carries the provider wiring" \
  "docker exec '$CONTAINER' sed -n '/^\[agents.default\]/,/^\[/p' '$CFG' | grep -q 'model_provider = \"custom.perkos\"'"
imageok "config: the ROUTED default agent carries the risk profile" \
  "docker exec '$CONTAINER' sed -n '/^\[agents.default\]/,/^\[/p' '$CFG' | grep -q 'risk_profile = \"perkos\"'"
# The trap that cost the P0 spike — an unconfigured risk profile boots fine and
# then fails every message with a generic LLM error.
cfgok "config: agent references the perkos risk profile" \
  '^risk_profile = "perkos"'
imageok "config: the perkos risk profile section exists" \
  "docker exec '$CONTAINER' grep -q '^\[risk_profiles.perkos\]' '$CFG'"
cfgok "config: memory search mode pinned to bm25 (no embedder shipped)" \
  '^search_mode = "bm25"'
cfgok "config: gateway binds the container interface" \
  '^host = "0\.0\.0\.0"'
cfgok "config: skill scripts enabled (perkos_tools.py must be runnable)" \
  '^allow_scripts = true'

# ── Persona ──────────────────────────────────────────────────────────────────
# The persona must live in the agent's OWN workspace — that is the only place
# the runtime discovers it. A copy at $HOME leaves the agent answering as a
# generic assistant while every config assertion still passes.
imageok "persona: AGENTS.md written into the routed agent's workspace" \
  "docker exec '$CONTAINER' grep -q 'PerkOS smoke-test agent' '$ZC_HOME/.zeroclaw/agents/default/workspace/AGENTS.md'"
imageok "persona: SOUL.md written into the routed agent's workspace" \
  "docker exec '$CONTAINER' grep -q 'PerkOS smoke-test agent' '$ZC_HOME/.zeroclaw/agents/default/workspace/SOUL.md'"
imageok "persona: the runtime itself reports the identity files as present" \
  "docker exec '$CONTAINER' zeroclaw doctor 2>&1 | grep -q '\[default\] AGENTS.md present'"
cfgok "persona: identity uses the OpenClaw format" \
  '^format = "openclaw"'

# ── Bundled skills staged into the agent's skills dir ────────────────────────
imageok "skills: perkos-platform-tools staged into the agent skills dir" \
  "docker exec '$CONTAINER' test -f '$ZC_HOME/skills/perkos-platform-tools/SKILL.md'"

# ── Auth contract the bridge depends on ──────────────────────────────────────
# Pre-seeded pairing: the delivery endpoint must REJECT an anonymous call and
# ACCEPT our minted bearer without any interactive pairing step.
code_anon="$(docker exec "$CONTAINER" curl -s -o /dev/null -w '%{http_code}' -m 10 \
  -X POST http://127.0.0.1:42617/webhook \
  -H 'content-type: application/json' -d '{"message":"ping"}' 2>/dev/null)"
if [ "$code_anon" = "401" ]; then
  pass "auth: /webhook rejects an unauthenticated call (401)"
else
  fail "auth: /webhook should 401 without a bearer, got '$code_anon'"
fi

code_auth="$(docker exec "$CONTAINER" curl -s -o /dev/null -w '%{http_code}' -m 25 \
  -X POST http://127.0.0.1:42617/webhook \
  -H "Authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' -d '{"message":"ping"}' 2>/dev/null)"
# The dummy LLM key cannot produce a real answer, so a 5xx is expected here.
# What we are asserting is that the PRE-SEEDED TOKEN was accepted, i.e. we got
# past auth without an interactive pairing exchange.
if [ "$code_auth" != "401" ] && [ -n "$code_auth" ]; then
  pass "auth: pre-seeded bearer accepted without interactive pairing (HTTP $code_auth)"
else
  fail "auth: pre-seeded bearer was rejected (HTTP $code_auth) — pairing is not pre-seeded"
fi

if [ "$ok" = "0" ]; then
  echo "ALL ZEROCLAW SMOKE CHECKS PASSED"
else
  echo "ZEROCLAW SMOKE CHECKS FAILED" >&2
fi
exit "$ok"
