---
topic: llm-options
audience: user
keywords: [llm, byok, openai, anthropic, model, key, perkos llm service]
last_reviewed: 2026-05-26
---

# LLM source — PerkOS LLM service vs BYOK vs Configure later

Step 4 of the wizard asks how the agent reaches its model.

## PerkOS LLM service

Managed Ollama-compatible gateway at `api.llm.perkos.xyz`. Today it hosts **kimi-k2.6:cloud** plus **qwen 7B/14B**. No key needed from you; PerkOS mints a per-agent Bearer key at provisioning time and injects it into the container's env. The agent uses the gateway's standard OpenAI-compatible `/v1/*` endpoints.

**Currently invite-only.** Your wallet has to be on the LLM allowlist. Ask a PerkOS admin to add you.

**Pick this when:** you want zero LLM operational overhead. You don't already have a provider key. You're OK with the model menu PerkOS curates.

## Bring your own key (BYOK)

You paste a key from your own provider (OpenAI, Anthropic, OpenRouter, etc.). PerkOS stashes it in AWS Secrets Manager and injects it into the container's env. **PerkOS never logs or proxies your traffic** — the agent calls your provider directly with your key.

**Pick this when:** you already have a provider key. You want a model not in the PerkOS LLM service menu (e.g. Claude Opus). You need provider-specific billing visibility.

**Caveat:** keys live in `perkos-agents/{wallet}/{name}/llm-key` in Secrets Manager, encrypted at rest with AWS KMS. Deleting the agent deletes the secret. We don't surface the key back to you after launch.

## Configure later

The agent boots without an LLM source. Useful for testing transport + tool calls only — the agent can receive messages and reply with hardcoded text, but won't actually think.

**Pick this when:** you're validating the wizard end-to-end. You'll configure the LLM by SSHing into the container and adding env vars yourself.

## Switching later

Same as deploy mode — delete + re-launch with the new LLM source. No migration; the persona + plugins travel via the global registry, not via the LLM choice.
