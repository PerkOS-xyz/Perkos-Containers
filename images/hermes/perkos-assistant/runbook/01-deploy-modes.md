---
topic: deploy-modes
audience: user
keywords: [deploy, ecs, fargate, vps, local, where to run]
last_reviewed: 2026-05-26
---

# Where your agent runs

Step 3 of the wizard asks "Where should this agent run?" Three options:

## PerkOS infra (AWS ECS Fargate)

PerkOS provisions a Fargate task for you. From **$29/mo** billed via x402 on the chain your wallet is connected to (Base or Celo today). Status flips to "ready" once the container is healthy, typically ~30s. Currently invite-only while we test — your wallet has to be on the ECS allowlist. Ask a PerkOS admin to add you.

**Pick this when:** you want PerkOS to handle the infra. You don't have a VPS. You want billing to be a single line on a single network.

**What's underneath:** 0.5 vCPU, 1 GB memory, on-demand Fargate in `us-east-1` (cluster `perkos-agents`). Real AWS cost is ~$18/mo; the $29 includes margin, logs, and transfer.

## Run on a VPS you own

You paste an SSH endpoint and a public key. PerkOS pushes an install script and watches the bridge come online. The agent runs on YOUR hardware; PerkOS only routes messages to it via `chat.perkos.xyz` and tasks via `transport.perkos.xyz`.

**Pick this when:** you already have a VPS (Hetzner, DigitalOcean, Linode, etc.). You want your own machine in your own logs. You're cost-sensitive at scale.

**Cost to you:** whatever your VPS costs. Most users land on a $5-10/mo Hetzner CX22.

## Run on my machine (Local)

PerkOS issues a relay credential. You paste it into your local OpenClaw or Hermes config and restart. No infra is provisioned by PerkOS. The agent runs on your laptop.

**Pick this when:** you're testing. You want to develop a custom plugin. Your agent doesn't need 24/7 uptime.

**Cost:** $0. Caveat: when your laptop sleeps, your agent sleeps with it.

## Switching modes later

The deploy mode is not load-bearing — only the credential changes. To move an agent from ECS to VPS, delete it (cleanup is automatic), re-launch with the new mode, same name. The persona, plugins, and conversation history travel with the registry, not the container.

(Once hibernation lands, this story improves: snapshot → restart on new infra → restore.)
