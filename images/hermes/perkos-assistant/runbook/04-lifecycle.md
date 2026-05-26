---
topic: agent-lifecycle
audience: user
keywords: [delete, hibernate, upgrade, lifecycle, billing stops]
last_reviewed: 2026-05-26
---

# Agent lifecycle — what each action does

## Launch

Wizard `→` `POST /api/agents/launch` `→` Firestore registry write `→` (if ECS) job enqueued `→` worker provisions Fargate task `→` status flips `provisioning → ready`. Typical: ~30-60s for ECS, instant for VPS / Local.

Your agent is now billing. ECS at ~$18/mo (actual AWS) → $29/mo (with margin) per the wizard quote.

## Delete

Agent detail page `→` Delete button `→` confirmation `→` `DELETE /api/agents/{id}`. Cleanup order:

1. **ECS service stopped + deleted** with `force=true`. Running tasks killed within seconds. **Billing stops immediately.**
2. **Secrets Manager secrets deleted** (`perkos-agents/{wallet}/{name}/llm-key`, `.../perkos-llm-key`) with no recovery window. The agent's LLM key is gone for good.
3. **LLM gateway key revoked** at `api.llm.perkos.xyz` (best-effort — a failure here surfaces as a warning but doesn't block).
4. **Firestore docs deleted** — `/wallets/{addr}/agents/{id}`, `/agents/{name}` global registry, `/agent_secrets/{addr}/agents/{id}`.

Conversations and tasks the agent was assigned to keep their history (the agent owns the canonical jsonl on its disk — but that disk is gone now, so practically: gone for the agent's perspective, kept where the user/other agents archived). This can't be undone.

Idempotent: if the agent never had ECS provisioning (VPS or Local mode), the AWS steps are no-ops and the cleanup still completes cleanly.

## Hibernate (coming soon)

Not shipped yet. The planned flow: detect idle for 30 min → graceful SIGTERM → snapshot state (`~/.hermes/profiles/`, `skills/`, `sessions/` for Hermes; `~/.openclaw/workspace/`, `credentials/` for OpenClaw) → upload to S3 → ECS scale to 0. Hibernated cost drops to ~$0.02/mo per agent (S3 storage).

Waking is symmetric: scale to 1 → download tarball → extract → runtime starts with full state. Cold start ~30-60s.

If you ask about hibernation today, say it's planned but not live. Don't suggest the user can hibernate something that has no button.

## Upgrade (coming soon)

Same plumbing as hibernate, but the new container starts on a different image tag. State snapshot is taken before the swap; if the new image fails health check, rollback restores the snapshot onto the previous image. Plugin diff is surfaced to the user as a one-shot banner post-upgrade.

Also not shipped yet. Today the way to upgrade is delete + re-launch with the new image tag.
