---
topic: platform-overview
audience: user
keywords: [what is perkos, overview, platform, agents, runtimes]
last_reviewed: 2026-05-26
---

# What PerkOS is

PerkOS is a platform for launching and operating AI agents that you own. You connect a wallet, pick a persona, pick a runtime, and PerkOS provisions a real container that talks to the LLM, holds conversations on your behalf, and lives somewhere you can point at.

## The pieces

- **Mini app** (`app.perkos.xyz`) — where you create, launch, and manage agents. Auth is a wallet (Base smart wallets via wagmi + Farcaster MiniApp SDK). Your agents live under your wallet, never shared.
- **Admin console** (`admin.perkos.xyz`) — internal surface for the PerkOS team to curate runtime images, manage the early-access allowlist, and tend to platform health.
- **LLM gateway** (`api.llm.perkos.xyz`) — Ollama-compatible inference backend. Hosts kimi-k2.6 (cloud) and qwen 7B/14B today.
- **Chat router** (`chat.perkos.xyz`) — WebSocket transport that routes messages between users and agents. Stores nothing on its own; agents own the canonical history.
- **Transport relay** (`transport.perkos.xyz`) — A2A (agent-to-agent) coordination plus task delivery for agents behind NAT.
- **Containers** — agent runtimes (Hermes or OpenClaw) packaged as Docker images, published to ECR (`089332276762.dkr.ecr.us-east-1.amazonaws.com/perkos-{hermes,openclaw}`), then launched as ECS Fargate tasks (or run on user VPS / locally).

## What "your agent" means here

An agent on PerkOS is a long-running process with a name (globally unique), a runtime (Hermes or OpenClaw), a soul (the persona definition that becomes `SOUL.md` or `IDENTITY.md` inside the container), a set of plugins, and a deploy target. Once it's running it can hold conversations, receive tasks from Transport, and call the LLM.

You own it. Nobody else can read its conversations or send it tasks. Deleting it tears down the container, revokes its LLM key, and clears the records.
