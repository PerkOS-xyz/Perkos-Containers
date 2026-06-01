#!/usr/bin/env bash
# Behavior test for a freshly-pushed runtime image.
#
# Provisions an ephemeral agent from the given image tag, sends a couple of
# canonical prompts (including a PM/plan-and-delegate prompt that reproduces
# the Hermes/Kimi "(empty)" failure mode), asserts the replies are
# substantive, tears the agent down, and posts the verdict back to
# PerkOS-API. A "fail" keeps the image un-promotable to the public channel.
#
# Design: FAIL-CLOSED. We only emit status="pass" when prompts genuinely
# returned substantive replies. Any prerequisite gap (missing token,
# provisioning timeout, empty reply) → status="fail" with a per-check detail
# and a non-zero exit. This guarantees the public-promotion gate never opens
# on an untested or broken image.
#
# Required env:
#   PERKOS_API_URL        base URL, e.g. https://api.perkos.xyz
#   RUNTIME_INGEST_KEY    shared secret for /internal/runtimes/behavior-test
#   BEHAVIOR_TEST_TOKEN   Firebase ID token for a super-admin/tester wallet
#                         (provisioning + chat are wallet-authenticated)
#
# Usage: run.sh <openclaw|hermes> <primaryTag>
set -uo pipefail

RUNTIME_LC="${1:?usage: run.sh <openclaw|hermes> <primaryTag>}"
PRIMARY_TAG="${2:?usage: run.sh <openclaw|hermes> <primaryTag>}"
case "$RUNTIME_LC" in
  openclaw) RUNTIME="OpenClaw";;
  hermes)   RUNTIME="Hermes";;
  *) echo "runtime must be openclaw or hermes" >&2; exit 2;;
esac

: "${PERKOS_API_URL:?PERKOS_API_URL is required}"
: "${RUNTIME_INGEST_KEY:?RUNTIME_INGEST_KEY is required}"

NOW() { date -u +%Y-%m-%dT%H:%M:%SZ; }
CHECKS="[]"   # JSON array accumulated via jq
add_check() { # name ok detail
  CHECKS="$(jq -c --arg n "$1" --argjson ok "$2" --arg d "${3:-}" \
    '. + [{name:$n, ok:$ok, detail:($d|select(.!="") // null)}]' <<<"$CHECKS")"
}

post_verdict() { # status
  local status="$1"
  local body
  body="$(jq -nc --arg r "$RUNTIME" --arg t "$PRIMARY_TAG" --arg s "$status" \
    --arg at "$(NOW)" --arg url "${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}" \
    --argjson checks "$CHECKS" \
    '{runtime:$r, primaryTag:$t, behaviorTest:{status:$s, runAt:$at, reportUrl:($url|select(.!="/"//"")), checks:$checks}}')"
  curl -sS -o /dev/null -w 'behavior-test post: HTTP %{http_code}\n' \
    -X POST "${PERKOS_API_URL}/internal/runtimes/behavior-test" \
    -H "content-type: application/json" \
    -H "x-runtime-ingest-key: ${RUNTIME_INGEST_KEY}" \
    --data "$body" || true
}

finish() { # status
  post_verdict "$1"
  [ "$1" = "pass" ] && exit 0 || exit 1
}

# --- prerequisites --------------------------------------------------------
if [ -z "${BEHAVIOR_TEST_TOKEN:-}" ]; then
  add_check "prerequisites" false "BEHAVIOR_TEST_TOKEN not set — cannot provision/chat"
  finish "fail"
fi
AUTH="Authorization: Bearer ${BEHAVIOR_TEST_TOKEN}"
API="$PERKOS_API_URL"
NAME="bt-${RUNTIME_LC}-$(date -u +%H%M%S)"

# --- launch ---------------------------------------------------------------
LAUNCH="$(curl -sS -X POST "${API}/agents/launch" -H "$AUTH" \
  -H "content-type: application/json" \
  --data "$(jq -nc --arg r "$RUNTIME" --arg n "$NAME" --arg tag "$PRIMARY_TAG" \
    '{runtime:$r, name:$n, imageTag:$tag, deployMode:"perkos-managed"}')")"
AGENT_ID="$(jq -r '.launchId // .result.agent.id // empty' <<<"$LAUNCH")"
JOB_ID="$(jq -r '.result.jobId // empty' <<<"$LAUNCH")"
if [ -z "$AGENT_ID" ]; then
  add_check "launch" false "no agentId in launch response: $(head -c 300 <<<"$LAUNCH")"
  finish "fail"
fi
add_check "launch" true "agentId=${AGENT_ID} jobId=${JOB_ID:-none}"

# --- wait until ready (provisioning job) ----------------------------------
READY=false
for _ in $(seq 1 60); do   # ~5 min max (5s * 60)
  if [ -n "$JOB_ID" ]; then
    ST="$(curl -sS "${API}/agents/jobs/${JOB_ID}" -H "$AUTH" | jq -r '.status // .state // empty')"
  else
    ST="$(curl -sS "${API}/agents/${AGENT_ID}" -H "$AUTH" | jq -r '.status // empty')"
  fi
  case "$ST" in
    ready|succeeded|done) READY=true; break;;
    failed|error) break;;
  esac
  sleep 5
done
if [ "$READY" != true ]; then
  add_check "provision-ready" false "agent did not reach ready (last status='${ST:-?}')"
  curl -sS -X DELETE "${API}/agents/${AGENT_ID}" -H "$AUTH" >/dev/null || true
  finish "fail"
fi
add_check "provision-ready" true ""

# --- prompts (assert substantive, non-empty replies) ---------------------
PROMPTS=(
  "Reply with a one-sentence confirmation that you are online."
  "You are the PM. Break the goal 'ship a landing page' into 3 delegated tasks with owners. Be concrete."
)
NAMES=("basic-reply" "${RUNTIME_LC}-non-empty-reply")
MIN_LEN=20
ALL_OK=true
for i in "${!PROMPTS[@]}"; do
  REPLY="$(curl -sS -X POST "${API}/assistant" -H "$AUTH" \
    -H "content-type: application/json" \
    --data "$(jq -nc --arg m "${PROMPTS[$i]}" --arg a "$AGENT_ID" \
      '{message:$m, agentId:$a}')" | jq -r '.reply // empty')"
  LEN="${#REPLY}"
  if [ -z "$REPLY" ] || [ "$LEN" -lt "$MIN_LEN" ]; then
    add_check "${NAMES[$i]}" false "empty/short reply (len=${LEN})"
    ALL_OK=false
  else
    add_check "${NAMES[$i]}" true "reply len=${LEN}"
  fi
done

# --- teardown -------------------------------------------------------------
curl -sS -X DELETE "${API}/agents/${AGENT_ID}" -H "$AUTH" >/dev/null || true
add_check "teardown" true ""

[ "$ALL_OK" = true ] && finish "pass" || finish "fail"
