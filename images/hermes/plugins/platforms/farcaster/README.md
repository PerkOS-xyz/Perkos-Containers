# hermes-platform-farcaster

Hermes platform plugin that lets an agent receive and reply to Farcaster casts via the [Neynar](https://neynar.com) hosted API.

Designed to be lifted out and contributed upstream as a standalone Hermes platform plugin (`hermes-platform-farcaster`). The code has zero PerkOS-specific imports; the only thing PerkOS-specific is how we ship it (baked into the `PerkOS-Hermes` image rather than installed by the user).

## What it does

| Direction | Mechanism |
|---|---|
| Inbound | Receives Neynar webhook deliveries at `/webhooks/farcaster` (mounted by Hermes's gateway HTTP server). Normalizes `cast.created` events into Hermes message events. |
| Outbound | Publishes casts via `POST /v2/farcaster/cast` signed by the agent's Neynar-managed `signer_uuid`. |
| Addressing | Default mode (`mentions`) only triggers a reply when the agent's `FID` appears in `mentioned_profiles`. Alternative `all` mode requires a `parent_channel` so the agent isn't responding to every cast on the network. |
| Security | Optional HMAC-SHA512 verification on inbound (`FARCASTER_WEBHOOK_SECRET`). The signer identity is fixed at provisioning time; the LLM cannot cast as anyone else. |

## Required env vars

| Var | Purpose |
|---|---|
| `FARCASTER_NEYNAR_API_KEY` | Bot identity for Neynar's API (read + write). |
| `FARCASTER_SIGNER_UUID` | The agent's Neynar-managed signer (created during provisioning). |
| `FARCASTER_FID` | The agent's Farcaster ID. Used to detect mentions. |

## Optional env vars

| Var | Default | Purpose |
|---|---|---|
| `FARCASTER_WEBHOOK_SECRET` | unset | HMAC secret for verifying inbound webhooks. When unset, signature check is skipped (acceptable in private/dev). |
| `FARCASTER_REPLY_VISIBILITY` | `mentions` | `mentions` only \| `all` (requires `FARCASTER_PARENT_CHANNEL`). |
| `FARCASTER_PARENT_CHANNEL` | unset | Channel parent URL to scope inbound + outbound. Required for `all` mode. |

## How Hermes loads it

Hermes's `PlatformRegistry` scans `$HERMES_HOME/plugins/platforms/*/plugin.yaml` at startup. Our `plugin.yaml` declares `entry_point: perkos_farcaster.plugin:register`. Hermes calls `register(ctx)` with a context exposing `register_platform()` and `http_client()`. The adapter is then instantiated by Hermes for each enabled platform — gated by the entry's `required_env`.

## Running the tests

```bash
cd images/hermes/plugins/platforms/farcaster
python3 -m pytest tests/ -v
```

No network; uses `FakeHttp` to verify call shape against Neynar's documented contract. 11 tests covering: connect handshake, send (success/failure/truncation/channel routing), inbound addressing (mentions vs all + channel scoping), HMAC verification (positive + negative), and defensive normalization of malformed payloads.

## Hibernation interaction

The adapter holds no persistent network connection — Neynar pushes webhooks to our HTTP endpoint when there's traffic. This means an agent in hibernation isn't actively maintaining a Farcaster session; the next webhook delivery wakes it via PerkOS's `ensureAwake` mechanism (called from the gateway HTTP handler before the inbound is dispatched). No connection state survives restart, and that's correct: Neynar handles retry.

## Not in scope at MVP

- Proactive casting (agent decides to cast unprompted). For v1 the agent only replies. A `cast` action skill can be added later.
- Multi-signer support (one agent = one signer). If a wallet wants two Farcaster identities, they own two agents.
- Hub-direct integration (bypassing Neynar). Operationally heavy for a per-agent container; see plugin.py docstring for the tradeoff.
- DM support — Neynar's DC API is in preview; we'll add it once stable.
