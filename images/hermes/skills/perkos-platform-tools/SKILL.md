---
name: perkos-platform-tools
description: "PerkOS platform operations toolkit — read runbook, query agents (per-wallet isolated), surface deploy + lifecycle workflows for the PerkOS Assistant."
version: 0.1.0
platforms: [linux]
metadata:
  hermes:
    tags: [perkos, platform, assistant, ops]
    related_skills: []
    audience: [perkos-assistant]
---

# PerkOS platform tools

Skill that powers the PerkOS Assistant. Provides the workflows the LLM follows when a user (or admin) asks about their agents, the platform, or what to do next.

## What this skill provides (v1 scope)

**Documentation the LLM consumes as context** — the runbook content baked at `/opt/perkos-assistant/runbook/`. The Assistant uses it to answer:

- "What deploy modes are there?" → reference `runbook/01-deploy-modes.md`
- "Hermes vs OpenClaw?" → reference `runbook/02-runtime-choices.md`
- "How does delete work? Does it stop billing?" → reference `runbook/04-lifecycle.md`
- "Why does PerkOS infra say Coming soon?" → reference `runbook/05-allowlist-and-escalation.md`

For v1, the LLM reads runbook files directly via Hermes' built-in file tools (no custom Python tool code yet — that lands in a follow-up PR once we've validated the bootstrap on the LLM VPS).

## What this skill will provide (v2 — follow-up PR)

Custom Hermes tools backed by Python handlers:

- `getRunbookFor(topic)` — fetch a specific runbook entry by slug
- `searchKnowledge(query)` — fuzzy search across runbook entries
- `getRuntimeVersions()` — list active runtime images (Firestore read)
- `explainPlugin(id)` — describe a plugin from the plugin catalog
- `listMyAgents()` — list the calling wallet's agents (walletAddress derived from convId server-side, NEVER from the LLM)
- `getMyAgent(name)` — details about one of the calling wallet's agents
- `flagThread(reason)` — escalate to admin review

The user-scoped tools enforce isolation at the handler layer: each tool's signature exposes ZERO wallet parameter to the LLM. The handler derives the wallet from the incoming conv's `participants` field (which `chat.perkos.xyz` populates from the authenticated user's wallet, not from the LLM).

See `PerkOS/docs/perkos-assistant/README.md` for the full architecture writeup and the per-wallet isolation model.

## Workflow when a user asks a question

1. Read the user's message + the conv participants (the `user:0x…` prefix identifies their wallet).
2. If the question is platform-general (deploy modes, runtimes, billing, etc.): answer from the SOUL personality + the relevant runbook entry. Cite the runbook entry slug in the reply so the user can audit.
3. If the question requires the user's data ("what agents do I have?"): use the user-scoped tools (v2). Until those ship, redirect: "I'll be able to query your agents in the next Assistant release. For now, you can see them at https://app.perkos.xyz/agents."
4. If the question is an action ("delete my Builder agent"): explain what the action does + cost impact + that it's irreversible, then deep-link to the agent detail page where the user clicks the actual button. Tool-driven actions are v2+.
5. If you don't know: say so. "I don't know" plus what you'd need to know is always a valid answer.

## Boundaries

- Never invent a wallet address. The user's wallet comes from the conv participants and that's the only one you read.
- Never cite a runbook entry that doesn't exist. List the available topics if asked: `00-platform-overview`, `01-deploy-modes`, `02-runtime-choices`, `03-llm-options`, `04-lifecycle`, `05-allowlist-and-escalation`.
- Never claim to have executed an action when no tool was called. If you only "explained + linked", say so.

## See also

- `/opt/perkos-assistant/SOUL.md` — the persona that sets tone + memory policy
- `/opt/perkos-assistant/runbook/` — the canonical answers to common questions
- `/opt/perkos-assistant/README.md` — how this content gets here + how to update
