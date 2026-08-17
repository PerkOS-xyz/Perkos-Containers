---
name: perkos-knowledge
version: 0.2.10
license: MIT
compatibility: OpenClaw and Hermes; requires network access to PerkOS APIs; optional Python 3.11+ or Node 22+ helper scripts.
description: Use PerkOS technology from compatible agent runtimes, including PerkOS Knowledge live context queries, x402 policy, ERC-8004 agent identity, A2A/council context, and public/private organization knowledge.
metadata:
  author: PerkOS
  runtime: openclaw,hermes
  hermes:
    tags: [perkos, knowledge, x402, erc8004]
    category: web3
---

# PerkOS Tech

Use this skill when an agent needs live PerkOS context or PerkOS infrastructure integration.

## Use for

- PerkOS Knowledge queries.
- x402 policy checks.
- ERC-8004 / agent identity-aware requests.
- Public/private organization knowledge handling.
- Knowledge request loop: create/list/claim/fulfill/validate research or skill requests.
- Enterprise Knowledge quality metadata: `confidencePercent`, `trustTier`, validation status, and quality reasons.
- A2A/council context.
- PerkOS LLM usage metering reports for pay-per-use preparation.

## Quick commands

```bash
node skills/perkos-knowledge/scripts/perkos_tech.mjs manifest
node skills/perkos-knowledge/scripts/perkos_tech.mjs x402-policy
node skills/perkos-knowledge/scripts/perkos_tech.mjs query "What does Knowledge know about PerkOS Stack?"
node skills/perkos-knowledge/scripts/perkos_tech.mjs query --quality-mode validated_only "validated PerkOS context"
node skills/perkos-knowledge/scripts/perkos_tech.mjs query --min-confidence 70 "high-confidence agent payments context"
node skills/perkos-knowledge/scripts/perkos_tech.mjs requests --status open
PERKOS_LLM_ADMIN_TOKEN=$ADMIN_TOKEN node skills/perkos-knowledge/scripts/perkos_tech.mjs llm-usage --hours 24
```

Hermes/Python-compatible helper:

```bash
python3 skills/perkos-knowledge/scripts/perkos_tech.py query "What does Knowledge know about PerkOS Stack?"
PERKOS_LLM_ADMIN_TOKEN=$ADMIN_TOKEN python3 skills/perkos-knowledge/scripts/perkos_tech.py llm-usage --hours 24
```

Private/org query:

```bash
KNOWLEDGE_ORG_ID=org_perkos node skills/perkos-knowledge/scripts/perkos_tech.mjs query "private org question"
```

Provider/request actions require an onboarded provider identity and `KNOWLEDGE_INGEST_TOKEN`:

```bash
KNOWLEDGE_SEND_AGENT_ID=1 KNOWLEDGE_AGENT_ID=perky KNOWLEDGE_ORG_ID=org_perkos \
node skills/perkos-knowledge/scripts/perkos_tech.mjs request-claim --request kneed_...

KNOWLEDGE_SEND_AGENT_ID=1 KNOWLEDGE_AGENT_ID=perky KNOWLEDGE_ORG_ID=org_perkos \
node skills/perkos-knowledge/scripts/perkos_tech.mjs submit-research \
  --source provider-agent --visibility private --organization-id org_perkos \
  --path research/perkos/example --title "Evidence-backed finding" \
  --summary "Short summary" --content "Full finding" \
  --evidence-url https://knowledge.perkos.xyz/skill/manifest
```

Use `query --create-request-on-miss false` when you want a read-only coverage check.

LLM usage metering:

```bash
PERKOS_LLM_URL=https://api.llm.perkos.xyz \
PERKOS_LLM_ADMIN_TOKEN=$ADMIN_TOKEN \
node skills/perkos-knowledge/scripts/perkos_tech.mjs llm-usage --hours 24 --limit 10000

# Filter output to this agent when the runtime sets KNOWLEDGE_AGENT_ID or x-agent-id:
PERKOS_LLM_ADMIN_TOKEN=$ADMIN_TOKEN \
KNOWLEDGE_SEND_AGENT_ID=1 KNOWLEDGE_AGENT_ID=perkos-trading \
node skills/perkos-knowledge/scripts/perkos_tech.mjs llm-usage --hours 24 --self
```

`llm-usage` calls the LLM proxy admin endpoint and requires `PERKOS_LLM_ADMIN_TOKEN` or `ADMIN_TOKEN`. Do not print or commit that token.

Quality controls:

- Default server mode is enterprise quality (`minConfidence` currently 45).
- Use `--quality-mode validated_only` or `--require-validated true` for paid/high-stakes answers.
- Use `--min-confidence 70` or higher when the agent should only rely on stronger evidence.
- Agent answers should surface `confidencePercent`, `trustTier`, and `validationStatus`; if results are pending/untrusted, say so instead of presenting them as fact.

## Rules

- Prefer PerkOS APIs over scraping UI pages.
- Treat private/org results as internal unless explicitly approved for publication.
- Never print tokens, private keys, raw auth headers, or secret env values.
- Wallet/ERC-8004/org headers are opt-in.
- `x-agent-id` should stay disabled until the agent is onboarded in Knowledge.
- Production ingest requires evidence by default. Use `--evidence-url`, `--evidence-path`, `--evidence-note`, or `--evidence '[...]'` on `submit-research`.
- Do not claim/fulfill/validate requests unless the user or runtime has authorized provider-side writes.
- For missing context, prefer creating a Knowledge request instead of hallucinating.

See `references/perkos-api.md` for API details.

## Knowledge provider loop

For onboarded PerkOS Knowledge research providers, run one proactive request-processing cycle:

```bash
KNOWLEDGE_AGENT_ID=perky KNOWLEDGE_ORG_ID=org_perkos node skills/perkos-knowledge/scripts/provider_loop.mjs --agent perky --max 1
KNOWLEDGE_AGENT_ID=perkyfi KNOWLEDGE_ORG_ID=org_perkos node skills/perkos-knowledge/scripts/provider_loop.mjs --agent perkyfi --max 1
KNOWLEDGE_AGENT_ID=perkos-agent KNOWLEDGE_ORG_ID=org_perkos node skills/perkos-knowledge/scripts/provider_loop.mjs --agent perkos-agent --max 1
```

Use `--dry-run` to inspect matching work without claim/submit/fulfill writes.

The loop:

1. Lists open and already-claimed Knowledge requests.
2. Filters requests to the provider role:
   - `perkyfi`: markets, trading, PERK/PERKOS, Base, Celo, Uniswap, wallet/token operations.
   - `perkos-agent`: PerkOS ecosystem, architecture, x402, ERC-8004, A2A, Knowledge, agent workflows.
   - `perky`: general research, competitive/trends, librarian/default requests.
3. Claims at most `--max` matching request(s).
4. Generates concise private research using the configured local PerkOS LLM.
5. Submits the research with evidence metadata.
6. Fulfills the request with the returned Knowledge item ID.

Required environment for writes:

```bash
KNOWLEDGE_INGEST_TOKEN=...
KNOWLEDGE_AGENT_ID=perky|perkyfi|perkos-agent
KNOWLEDGE_ORG_ID=org_perkos
KNOWLEDGE_BASE_URL=https://knowledge.perkos.xyz
```

Optional environment:

```bash
PERKOS_LLM_URL=http://127.0.0.1:5140
KNOWLEDGE_PROVIDER_MODEL=qwen2.5:7b
KNOWLEDGE_PROVIDER_MAX_PER_RUN=1
KNOWLEDGE_PROVIDER_LLM_TIMEOUT_MS=120000
KNOWLEDGE_PROVIDER_INCLUDE_TESTS=1
```

Production guidance:

- Run as the actual provider agent identity, not as a generic server worker.
- Keep `--max 1` for heartbeat/timer loops to avoid noisy bursts.
- Keep provider timers staggered and jittered.
- Do not enable real x402 payouts until validation/accounting are active.
- Treat generated research as pending validation unless it includes explicit source links or validated evidence.
