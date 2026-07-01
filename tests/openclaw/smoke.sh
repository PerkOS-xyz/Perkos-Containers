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
  # Provider key is dynamic (__PERKOS_LLM_PROVIDER__ → "ollama" by default,
  # "openai" for BYOK). Read the first (only) provider rather than assuming
  # its name.
  jqok "baseline: provider baseUrl substituted"         '(.models.providers | to_entries[0].value.baseUrl) == "https://api.llm.perkos.xyz"'
  jqok "baseline: provider apiKey substituted"          '(.models.providers | to_entries[0].value.apiKey) == "dummy-llm-key"'
  jqok "baseline: agent id header substituted"          '(.models.providers | to_entries[0].value.headers["x-agent-id"]) == "smoke-test"'
  jqok "baseline: default provider key is ollama"       '(.models.providers | has("ollama"))'
  jqok "baseline: no unsubstituted __PLACEHOLDER__ left" \
       '[.. | strings | select(startswith("__") and endswith("__"))] | length == 0'

  # Persona must NOT be written when the env var is absent.
  if docker exec "$CONTAINER" test -f "$AGENTS_MD" 2>/dev/null; then
    fail "baseline: AGENTS.md should NOT exist without PERKOS_AGENT_SOUL_B64"
  else
    pass "baseline: no AGENTS.md without persona env (correct)"
  fi

  # Hibernation snapshot/restore: scripts baked + executable, AWS CLI present,
  # and the snapshot no-op contract (skips cleanly when no S3 URI is set).
  if docker exec "$CONTAINER" test -x /usr/local/bin/perkos-snapshot.sh \
     && docker exec "$CONTAINER" test -x /usr/local/bin/perkos-restore.sh; then
    pass "hibernation: snapshot.sh + restore.sh installed + executable"
  else
    fail "hibernation: snapshot.sh/restore.sh missing or not executable"
  fi
  if docker exec "$CONTAINER" aws --version >/dev/null 2>&1; then
    pass "hibernation: aws CLI present (can call S3 + KMS)"
  else
    fail "hibernation: aws CLI missing — snapshot/restore will fail at runtime"
  fi
  if docker exec "$CONTAINER" sh -c \
      "env -u PERKOS_HIBERNATION_S3_URI /usr/local/bin/perkos-snapshot.sh 2>/dev/null" \
      | grep -qE '"skipped":\s*true'; then
    pass "hibernation: snapshot.sh no-op when PERKOS_HIBERNATION_S3_URI unset"
  else
    fail "hibernation: snapshot.sh should skip with JSON status when S3 URI unset"
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

# ---------------------------------------------------------------
# Pass 4: open-source skills install from PERKOS_AGENT_SKILLS_B64.
# The entrypoint must (a) fetch an allow-listed SKILL.md into the
# workspace skills dir, (b) skip a non-allow-listed host, and (c)
# never crash boot on a bad fetch.
# ---------------------------------------------------------------
SKILLS_DIR=/home/node/.openclaw/workspace/skills
# A real, SHA-pinned ethskills security SKILL.md on the only allow-listed
# host (raw.githubusercontent.com). CI has network; this is a stable pin.
GOOD_URL="https://raw.githubusercontent.com/austintgriffith/ethskills/191dcc1ead0182aab16d4c742bee8b15f2d0d8d7/security/SKILL.md"
SKILLS_JSON="[{\"name\":\"smoke-good\",\"url\":\"${GOOD_URL}\"},{\"name\":\"smoke-evil\",\"url\":\"https://evil.example.com/x/SKILL.md\"}]"
SKILLS_B64="$(printf '%s' "$SKILLS_JSON" | base64 | tr -d '\n')"

if run_container perkos-openclaw-smoke-skills-$$ -e PERKOS_AGENT_SKILLS_B64="$SKILLS_B64"; then
  # Give the boot-time fetch a moment.
  waited=0
  while [ "$waited" -lt 20 ]; do
    docker exec "$CONTAINER" test -f "$SKILLS_DIR/smoke-good/SKILL.md" 2>/dev/null && break
    sleep 1; waited=$((waited + 1))
  done
  if docker exec "$CONTAINER" test -f "$SKILLS_DIR/smoke-good/SKILL.md" 2>/dev/null; then
    pass "skills: allow-listed SKILL.md installed"
  else
    fail "skills: allow-listed SKILL.md not installed (network? entrypoint?)"
  fi
  # Non-allow-listed host must be skipped — its dir must NOT exist.
  if docker exec "$CONTAINER" test -e "$SKILLS_DIR/smoke-evil" 2>/dev/null; then
    fail "skills: non-allow-listed host was NOT skipped"
  else
    pass "skills: non-allow-listed host skipped (correct)"
  fi
  # Boot still healthy → fetch step degraded, didn't crash.
  if docker exec "$CONTAINER" test -f "$CFG" 2>/dev/null; then
    pass "skills: boot survived the install step"
  else
    fail "skills: boot did not complete config render"
  fi
fi

# ---------------------------------------------------------------
# Pass 5: resilience — a payload of ONLY a bad/non-allow-listed entry
# must not create anything and must not crash boot.
# ---------------------------------------------------------------
BAD_B64="$(printf '%s' '[{"name":"only-evil","url":"http://169.254.169.254/latest/meta-data/"}]' | base64 | tr -d '\n')"
if run_container perkos-openclaw-smoke-skills-bad-$$ -e PERKOS_AGENT_SKILLS_B64="$BAD_B64"; then
  if docker exec "$CONTAINER" test -e "$SKILLS_DIR/only-evil" 2>/dev/null; then
    fail "skills: SSRF-style metadata URL was NOT blocked"
  else
    pass "skills: metadata/non-https URL blocked + boot survived"
  fi
fi

# ---------------------------------------------------------------
# Pass 6: multi-agent (co-resident agents) — Phase 1, NON-FATAL.
# Boot with PERKOS_PROFILES_B64 (2 co-residents) + a primary persona; check the
# renderer patched agents.list (primary default:true + co-residents) and wrote
# each co-resident's AGENTS.md. Reports in the CI log WITHOUT gating image
# promotion — the OpenClaw multi-agent boot is still being proven (mirrors the
# Hermes rollout; flip to hard once green).
# ---------------------------------------------------------------
echo "== multi-agent (co-resident agents) — non-fatal =="
mp_pass=0
mp_warn=0
MP_SR="$(printf '%s' '# Researcher' | base64 | tr -d '\n')"
MP_BK="$(printf '%s' '# Bookkeeper' | base64 | tr -d '\n')"
MP_PRIMARY="$(printf '%s' '# PM primary' | base64 | tr -d '\n')"
MP_JSON="[{\"id\":\"researcher\",\"name\":\"Researcher\",\"soulB64\":\"${MP_SR}\"},{\"id\":\"bookkeeper\",\"name\":\"Bookkeeper\",\"soulB64\":\"${MP_BK}\"}]"
MP_B64="$(printf '%s' "$MP_JSON" | base64 | tr -d '\n')"
if run_container perkos-openclaw-smoke-multiagent-$$ \
    -e PERKOS_PROFILES_B64="$MP_B64" -e PERKOS_AGENT_SOUL_B64="$MP_PRIMARY"; then
  if docker exec "$CONTAINER" sh -c "jq -e '.agents.list | length == 3' $CFG" >/dev/null 2>&1; then
    echo "  OK  multi-agent: agents.list has 3 agents (primary + 2 co-resident)"; mp_pass=$((mp_pass + 1))
  else echo "  WARN multi-agent: agents.list is not 3 agents"; mp_warn=$((mp_warn + 1)); fi
  if docker exec "$CONTAINER" sh -c "jq -e '[.agents.list[] | select(.default==true)] | length == 1' $CFG" >/dev/null 2>&1; then
    echo "  OK  multi-agent: exactly one default agent (the primary)"; mp_pass=$((mp_pass + 1))
  else echo "  WARN multi-agent: default-agent count != 1"; mp_warn=$((mp_warn + 1)); fi
  if docker exec "$CONTAINER" test -f /home/node/.openclaw/workspace-researcher/AGENTS.md 2>/dev/null; then
    echo "  OK  multi-agent: researcher AGENTS.md written to its workspace"; mp_pass=$((mp_pass + 1))
  else echo "  WARN multi-agent: researcher AGENTS.md missing"; mp_warn=$((mp_warn + 1)); fi
  if docker exec "$CONTAINER" test -f /home/node/.openclaw/workspace-bookkeeper/AGENTS.md 2>/dev/null; then
    echo "  OK  multi-agent: bookkeeper AGENTS.md written to its workspace"; mp_pass=$((mp_pass + 1))
  else echo "  WARN multi-agent: bookkeeper AGENTS.md missing"; mp_warn=$((mp_warn + 1)); fi
  sleep 10
  mp_state=$(docker inspect "$CONTAINER" --format '{{.State.Status}}' 2>/dev/null || echo missing)
  mp_restarts=$(docker inspect "$CONTAINER" --format '{{.RestartCount}}' 2>/dev/null || echo 0)
  if [ "$mp_state" = "running" ] && [ "$mp_restarts" -eq 0 ]; then
    echo "  OK  multi-agent: gateway stable with agents.list (state=$mp_state restarts=$mp_restarts)"; mp_pass=$((mp_pass + 1))
  else
    echo "  WARN multi-agent: gateway NOT stable (state=$mp_state restarts=$mp_restarts) — non-fatal"; mp_warn=$((mp_warn + 1))
    docker logs "$CONTAINER" 2>&1 | tail -15 | sed 's/^/  /' || true
  fi
fi
echo "== multi-agent: ${mp_pass} passed, ${mp_warn} warned (non-fatal) =="

exit "$ok"
