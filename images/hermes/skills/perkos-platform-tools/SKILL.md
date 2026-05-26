---
name: perkos-platform-tools
description: "PerkOS platform operations toolkit — read runbook, search knowledge, query the caller's own agents (per-wallet isolated), explain plugins. Backed by the Platform Tools API."
version: 0.2.0
platforms: [linux]
metadata:
  hermes:
    tags: [perkos, platform, assistant, ops]
    related_skills: []
    audience: [perkos-assistant]
---

# PerkOS platform tools

Skill that powers the PerkOS Assistant. Two complementary surfaces:

1. **Bundled runbook (markdown context)** at `/opt/perkos-assistant/runbook/` — the LLM reads these for general "how does X work" answers. Cite the slug.
2. **Platform Tools API (live calls)** via `scripts/perkos_tools.py` — for dynamic per-caller queries (the user's own agents) and structured knowledge search.

## Live tools (v0.2 — Platform Tools API)

The wrapper script `scripts/perkos_tools.py` calls the PerkOS Platform Tools API. It NEVER asks the LLM for the caller's wallet — the wallet is derived server-side from the chat conversation. The LLM only supplies:

- `--conv-id <id>` — the conversation id from the `[PERKOS_CHAT:<id>]` marker in the system message.
- `<toolName>` and `<argsJson>` — the tool to call and its inputs.

Available tools (response shape: `{ ok, data?, errorClass?, message? }`):

| Tool | Inputs | What it returns |
|---|---|---|
| `getRunbookFor` | `{"topic":"04-lifecycle"}` (slug or stem) | `{ content, source }` — full markdown of the runbook entry |
| `searchKnowledge` | `{"query":"fargate ecs","limit":5}` | `{ hits: [{ topic, excerpt, score }] }` |
| `listMyAgents` | `{}` | `{ agents: [{ name, status, ... }] }` — the CALLER's agents only |
| `getMyAgent` | `{"name":"MyBuilder"}` | `{ agent: { ... } }` — only if owned by the caller |
| `explainPlugin` | `{"pluginId":"github"}` | `{ id, label, description, requires, examples }` |

### Calling pattern

```bash
# List the caller's agents.
python3 /opt/data/skills/perkos-platform-tools/scripts/perkos_tools.py \
    call listMyAgents '{}' \
    --conv-id "$CONV_ID"

# Search the runbook + curated knowledge.
python3 /opt/data/skills/perkos-platform-tools/scripts/perkos_tools.py \
    call searchKnowledge '{"query":"fargate","limit":3}' \
    --conv-id "$CONV_ID"

# Read a specific runbook entry.
python3 /opt/data/skills/perkos-platform-tools/scripts/perkos_tools.py \
    call getRunbookFor '{"topic":"04-lifecycle"}' \
    --conv-id "$CONV_ID"
```

`$CONV_ID` is the conv id from the `[PERKOS_CHAT:<id>]` system marker. The script will refuse to run without it (exit 4).

### Exit codes

| code | meaning |
|---|---|
| 0 | tool returned `ok: true` |
| 2 | tool returned `ok: false` (bad input, not-found, etc) — read `errorClass` |
| 3 | bridge or Tools API unreachable / 5xx |
| 4 | bad usage (missing env, malformed args) |

### Authorization model (why you can't impersonate other wallets)

The Tools API enforces tenant isolation at THREE layers; the LLM is forced to be honest by construction:

1. The bridge process is the only entity with the Tools-API HMAC secret. The LLM never sees it.
2. The bridge mints a JWT bound to the wallet from the **active chat conversation** (not from a runtime parameter). When the LLM asks for a token, the bridge looks up the convId in its registry and signs with the conv's wallet — no wallet input is accepted.
3. Tools like `listMyAgents` / `getMyAgent` derive `walletAddress` from the JWT claim, not from request body. So even if the LLM crafted a body with `{ "walletAddress": "0xother" }`, it would be ignored.

This means: **the LLM cannot list another wallet's agents even if it tries to**. State this when asked.

## Workflow when a user asks a question

1. Read the user's message + the `[PERKOS_CHAT:<convId>]` marker. Extract `convId`.
2. Decide the question class:
   - **Platform-general** ("what deploy modes are there?") → call `getRunbookFor` or `searchKnowledge`; cite the slug in your reply.
   - **Caller's data** ("what agents do I have?") → call `listMyAgents` / `getMyAgent`. The walletAddress is derived server-side; do not ask the user for it.
   - **Action** ("delete my Builder agent") → explain what it does + cost impact + that it's irreversible, then deep-link to `https://app.perkos.xyz/agents/<name>`. Tool-driven actions ship in v3.
3. If `searchKnowledge` returns hits, follow up with `getRunbookFor` on the top hit to read the full entry before answering.
4. If a tool returns `ok: false`, surface the `errorClass` honestly. Common ones:
   - `NOT_FOUND` — the topic / agent / plugin doesn't exist (list available options if known)
   - `RATE_LIMITED` — too many calls; ask the user to wait
   - `BAD_INPUT` — your args were malformed (re-read this SKILL.md)
   - `UNAVAILABLE` — Firestore or another dep is down; report the outage

## Boundaries

- Never ask the user for their wallet. The convId IS the identity.
- Never invent agent names. If `listMyAgents` returns empty, say "you don't have any agents yet" — don't fabricate.
- Never cite a runbook topic that doesn't exist. The fixed set: `00-platform-overview`, `01-deploy-modes`, `02-runtime-choices`, `03-llm-options`, `04-lifecycle`, `05-allowlist-and-escalation`.
- Never claim to have executed an action when you only emitted a link. Use language like "you can do that here: <link>" not "I deleted it for you".

## See also

- `references/examples.md` — copy-pasteable bash for common queries
- `/opt/perkos-assistant/SOUL.md` — the persona that sets tone + memory policy
- `/opt/perkos-assistant/runbook/` — the canonical answers (also exposed via `getRunbookFor`)
