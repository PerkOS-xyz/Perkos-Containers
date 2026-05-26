---
topic: allowlist-escalation
audience: user
keywords: [allowlist, access denied, coming soon, talk to admin, support]
last_reviewed: 2026-05-26
---

# Why some options say "Coming soon" + how to escalate

PerkOS has a few features gated by per-wallet allowlists while we test:

## Three allowlists today

1. **App access** (`/access` in admin) — base eligibility to use the PerkOS app at all. Without this, sign-in succeeds via Firebase but the app routes you to a "request access" page.
2. **ECS access** (`/ecs-access` in admin) — eligibility to pick "PerkOS infra (AWS ECS)" as a deploy mode in the wizard. Without this, the option shows "Coming soon" and is disabled.
3. **LLM access** (`/llm-access` in admin) — eligibility to pick "PerkOS LLM service" in step 4. Without this, the option shows "Coming soon" and is disabled.

These are independent. A wallet can be on the app allowlist but not the ECS one, or on ECS but not LLM (e.g. "wants to BYOK their own LLM provider but use PerkOS infra").

The cascade for app access: `config/access.publicMode` → env `PERKOS_WHITELIST` → Firestore `/allowlist/{addr}`. Super-admins (env `PERKOS_SUPER_ADMINS` + Firestore `/super_admins`) bypass all three.

## What I tell the user when they hit one

- "PerkOS infra is currently invite-only while we test. You can launch on a VPS or locally today, or message an admin to be added to the early-access list."
- "PerkOS LLM service is currently invite-only. BYOK with OpenAI / Anthropic / OpenRouter works today, or message an admin."
- "I'd need an admin to add your wallet (`0xc256…`) to the ECS access list — that lives at `admin.perkos.xyz/ecs-access`. Want me to flag this thread for the team?"

## When billing ships

The allowlists collapse into subscriptions. `/ecs_allowlist` becomes `/ecs_subscriptions` with payment fields; admin-manual entries become the comp / friends-and-family list. Same for LLM. Public users will subscribe via x402 (monthly, on Base or Celo) instead of waiting on an admin.

## Escalation to a human

If I can't solve a problem (rare but possible), I can flag the conversation for admin review. The user sees:

> "I'm not sure how to answer this — I'll flag it for the PerkOS team. Expect a reply within 24h on this same thread, or sooner if you can ping us on Telegram/Discord."

Flagging writes to `/flagged_threads/{convId}` with the wallet, the last message, and a one-line "why I flagged" reason. Admins see flagged threads in `admin.perkos.xyz` (when that surface ships).
