# PerkOS Assistant — deploy runbook

Manual deploy to the LLM VPS at `46.225.62.30` (SSH key `~/.ssh/perkos-cloud-agents-hetzner`). The Assistant is not part of the ECS fleet — it runs as a long-lived Docker container on the same VPS as the LLM gateway so the inference RTT is loopback-fast.

## Prerequisites

- A super-admin Firebase ID token on the wallet that controls `app.perkos.xyz`. The token expires in ~1 hour; mint a fresh one right before running step 1.
- SSH access to `root@46.225.62.30` with `~/.ssh/perkos-cloud-agents-hetzner`.
- Docker on the VPS (already there — version 29.1.3 as of 2026-05-26).

## One-time bootstrap

### Step 1 — Register the platform agent (run locally)

```bash
# Get a fresh Firebase token from the browser:
#   F12 → console → await firebase.auth().currentUser.getIdToken(true)

TOKEN="paste-the-token-here"

curl -sS -X POST https://app.perkos.xyz/api/agents/launch \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "kind": "platform",
    "name": "PerkOS-Assistant",
    "runtime": "Hermes",
    "plugins": ["perkos-platform-tools"]
  }' | jq
```

Save two fields from the response — they are one-shot:

- `result.agent.id` → goes into `.env` as `PERKOS_AGENT_ID`
- `credentials.relayApiKey` → goes into `.env` as `PERKOS_RELAY_API_KEY`

If `name "PerkOS-Assistant" is already taken`, the registry already has the agent. Delete the existing record first via `DELETE /api/agents/PerkOS-Assistant` (requires the platform-delete flag, not shipped yet — for now, manually delete `/agents/PerkOS-Assistant` and `/platform_agents/PerkOS-Assistant` in the Firebase console).

### Step 2 — Lay down the source on the VPS

```bash
ssh -i ~/.ssh/perkos-cloud-agents-hetzner root@46.225.62.30 '
  mkdir -p /opt/perkos-assistant /var/perkos-assistant/hermes
  cd /opt/perkos-assistant
  if [ ! -d Perkos-Containers ]; then
    git clone https://github.com/PerkOS-xyz/Perkos-Containers.git
  else
    cd Perkos-Containers && git pull
  fi
'
```

### Step 3 — Configure secrets

Copy the env example and fill in the two values from step 1:

```bash
ssh -i ~/.ssh/perkos-cloud-agents-hetzner root@46.225.62.30 '
  cd /opt/perkos-assistant/Perkos-Containers/deploy/perkos-assistant
  if [ ! -f .env ]; then cp .env.example .env; fi
  echo "Now edit /opt/perkos-assistant/Perkos-Containers/deploy/perkos-assistant/.env"
'
```

Then edit the file (`vim`, `nano`, whatever) and set:

- `PERKOS_AGENT_ID` — from step 1
- `PERKOS_RELAY_API_KEY` — from step 1
- `PERKOS_LLM_API_KEY` — leave as the default `allowlisted-vps-temporary` (the gateway honors this magic key for the local VPS)

### Step 4 — Build + run

```bash
ssh -i ~/.ssh/perkos-cloud-agents-hetzner root@46.225.62.30 '
  cd /opt/perkos-assistant/Perkos-Containers/deploy/perkos-assistant
  docker compose build perkos-assistant
  docker compose up -d
  sleep 5
  docker logs -n 50 perkos-assistant
'
```

First build takes ~2-3 min (pulls `nousresearch/hermes-agent:latest`, installs `@perkos/perkos-a2a@0.11.0` — which ships the gateway-health reporter — copies the SOUL + runbook content).

### Step 5 — Verify

```bash
# Container healthy?
ssh -i ~/.ssh/perkos-cloud-agents-hetzner root@46.225.62.30 \
  'docker inspect perkos-assistant --format "{{.State.Health.Status}}"'

# Should print "healthy" within ~30s of starting.

# Chat router auth check: tail the logs and look for the perkos-a2a
# bridge confirming it connected to chat.perkos.xyz as agent:PerkOS-Assistant.
ssh -i ~/.ssh/perkos-cloud-agents-hetzner root@46.225.62.30 \
  'docker logs -f perkos-assistant 2>&1 | grep -E "chat|relay|connect"'
```

Look for lines like:

- `connected to wss://chat.perkos.xyz/chat as agent:PerkOS-Assistant`
- `relay key accepted`
- `subscribed to N conversations`

## Updating

Image bumps (new SOUL content, new runbook entries, new skill code):

```bash
ssh -i ~/.ssh/perkos-cloud-agents-hetzner root@46.225.62.30 '
  cd /opt/perkos-assistant/Perkos-Containers
  git pull
  cd deploy/perkos-assistant
  docker compose build perkos-assistant
  docker compose up -d
'
```

Identity stays the same across rebuilds; only the code/content changes. Hermes state at `/var/perkos-assistant/hermes/` survives (bind mount).

## Tearing down

```bash
ssh -i ~/.ssh/perkos-cloud-agents-hetzner root@46.225.62.30 '
  cd /opt/perkos-assistant/Perkos-Containers/deploy/perkos-assistant
  docker compose down
  # Optional — full wipe (loses chat history):
  # rm -rf /var/perkos-assistant/hermes
'
```

To unregister the agent from Firestore + revoke its LLM key, hit `DELETE /api/agents/PerkOS-Assistant` (requires the platform-delete flag — currently manual via Firebase console).

## What this deploys

A single Hermes process running:
- The `perkos-platform-tools` skill (documentation-only at v1 — workflows the LLM reads as context)
- The PerkOS-Assistant SOUL as the system prompt
- The `perkos-a2a` bridge connecting outbound to `chat.perkos.xyz` + `transport.perkos.xyz`
- LLM inference via the local gateway at `api.llm.perkos.xyz`

It DOES NOT yet have:
- Custom Python tool handlers (`getRunbookFor`, `listMyAgents`, etc.) — those land in the follow-up PR after this is validated
- Firebase Admin SDK credentials — needed for the user-scoped tools, deferred to that follow-up
- A user-facing chat UI in the miniapp — `ChatbotPanel` rewires to chat.perkos.xyz in a separate PR

## Operational notes

- **Logs:** `docker logs -f perkos-assistant`
- **Restart:** `docker compose restart perkos-assistant`
- **Network:** the container talks outbound only; no inbound ports published. Caddy and the firewall don't need any changes.
- **Disk:** Hermes state at `/var/perkos-assistant/hermes/` grows with conversation history. Cap is currently soft — monitor with `du -sh /var/perkos-assistant/hermes/`.
- **Cost:** $0 incremental (runs on the existing LLM VPS; LLM inference is free until billing lands).
