---
topic: runtime-choices
audience: user
keywords: [hermes, openclaw, runtime, which agent runtime, comparison]
last_reviewed: 2026-05-26
---

# Hermes vs OpenClaw

Step 2 of the wizard asks you to pick a runtime. Both work with PerkOS-Transport, swarm coordination, and the Council. The version shown for each is the one the PerkOS team has approved for the current release.

## Hermes

A conversational + tooling agent optimized for fast interactive replies. Written in Python.

**Best at:**
- Chat-driven workflows where latency matters
- Strong message routing across channels
- Customer ops and creative work
- Long sessions with rich memory (skills hub, profiles, sessions/)

**State layout:** `~/.hermes/profiles/{name}/` for config, `~/.hermes/skills/` for installed plugins, `~/.hermes/sessions/` for conversations.

## OpenClaw

An autonomous executor focused on long-running, tool-driven workflows. Written in TypeScript.

**Best at:**
- Multi-step task execution
- Built-in browser and code-runner tooling
- Research, automation, and ops
- Workspace-style operation (`~/.openclaw/workspace/`)

**State layout:** `~/.openclaw/workspace/` for working data, `~/.openclaw/credentials/` for channel/provider creds, `~/.openclaw/agents/{agentId}/agent/auth-profiles.json` for model auth.

## Which one for which persona

A loose rule of thumb based on what the personas in the wizard ship today:

- **Builder, Reviewer, QA, Trader, Ops** → Hermes is the validated combo with kimi-k2.6:cloud on our LLM gateway.
- **Researcher, Analyst, Knowledge, Workflow** → OpenClaw if you want browser + code-runner tooling out of the box; Hermes otherwise.
- **Support, Concierge, Marketing, Sales, Recruiter, Security** → either; Hermes for faster reply latency, OpenClaw for tool-heavy flows.

You can change your mind later by deleting and re-launching with the other runtime. State migration between Hermes and OpenClaw is not supported — they have different on-disk schemas.

## Versions

The version shown ("latest-perkos.YYYY.MM.DD.hash") is pinned by the admin. The wizard only shows runtimes the admin has activated; if you don't see one, the team hasn't approved a build of it for this release.
