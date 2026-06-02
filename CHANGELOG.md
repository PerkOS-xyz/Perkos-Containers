# Changelog

All notable changes to PerkOS-Containers are recorded here.

Format: one section per release / notable change, newest first. Each entry
captures *what shipped* and the *why* — the equivalent of a good commit body,
collected here so operators don't have to spelunk `git log`. Tag-style
versions are optional; date-stamped sections are fine for in-flight work.

## 2026-06-01

### Weekly reproducible releases: digest pin + beta channel + behavior test

The build pipeline now produces a **weekly, reproducible, behavior-tested**
release instead of a manual `:latest` rebuild:

- **Cron**: `build-push-ecr.yml` runs every Monday 06:00 UTC (still triggers
  on `images/**` push + `workflow_dispatch`).
- **Digest pin**: a "Resolve upstream digest" step turns the moving
  `openclaw/hermes :latest` into a concrete `@sha256` and builds `FROM` it,
  so a release can always be rebuilt identically. The OCI
  `org.opencontainers.image.version` label is read and baked as
  `perkos.upstream-version`. Dockerfiles gained `OPENCLAW_REF`/`HERMES_REF`
  (+ `*_VERSION`) args; they default to `:latest` so local builds are
  unchanged.
- **Registration**: after push, `scripts/ingest-runtime-image.sh` POSTs the
  new tag to PerkOS-API `/internal/runtimes/ingest` (API-key auth via
  `RUNTIME_INGEST_KEY`). The image lands on the **beta** channel with its
  resolved upstream + build status and a *pending* behavior test.
- **Behavior test** (`tests/behavior/run.sh`, job `behavior-test`):
  provisions an ephemeral agent from each freshly-pushed tag in real ECS and
  gates on the **operational lifecycle** — launch → task RUNNING → the
  perkos-a2a bridge dialing out and registering as `bridgeConnected` (via
  heartbeat) → clean teardown. **Fail-closed**: only a green lifecycle lets an
  admin later promote the image to the public channel.
  - Reply-QUALITY (GATING — root cause fixed): the test calls PerkOS-API
    `POST /internal/runtimes/probe-agent` (relay discover-gate → A2A task →
    task_response) and asserts a substantive (non-empty, ≥20 char) reply to
    two canonical prompts. The "flap" turned out to be **the probe crashing the
    bridge**: CloudWatch bridge logs showed `Task … received` →
    `TypeError: Cannot read properties of undefined (reading 'parts')` at
    `server.js:234` → Node process crash → reconnect. The bridge feeds the
    relay `payload` into A2A `message/send` (`params.message.parts`); our bare
    `{text}` payload made `message` undefined. Fix (probe-side, no bridge
    rebuild): send the proper A2A message envelope
    (`{message:{role,kind,messageId,parts:[{kind:text,text}],metadata}}`).
    Validated against the persistent `Perkos-Hermes-Tester` bridge (real 216-char
    reply, no crash). Probe also hardened: discover-gate, 25s heartbeats, A2A
    Task reply parsing, `(empty reply)` sentinel. Pass now requires lifecycle
    AND substantive replies.

#### Validation history (e2e dispatch runs, 2026-06-01)

The behavior test was hardened by repeated real `workflow_dispatch` runs; each
caught a concrete bug, fail-closed every time, and left ECS clean:
- `-e2e`: missing `walletAddress` on launch (test bug) → fixed.
- fix run: PerkOS-API `createJob` persisted `undefined` soul → Firestore
  rejected it (prod bug, any soul-less launch) → `stripUndefined()`.
- `-e2e2`: real provision green (launch→ready→teardown), replies empty →
  diagnosed: wrong endpoint (`/assistant` vs the Concierge) + async reply path.
- `-e2e3`: added bridge-connected warmup; lifecycle green.
- final: probe-agent A2A round-trip wired for true reply-quality gating.

#### CI cron disabled

The weekly `schedule` was removed — releases run on `workflow_dispatch` or on
push to `images/**`/`tests/**`. Restore the `schedule:` block in the workflow
to re-enable the Monday 06:00 UTC run.
- **A2A pin**: workflow bumped `PERKOS_A2A_VERSION` 0.11.0 → 0.12.0 to match
  the bridge Dockerfile default and the Assistant compose (all three 0.12.0).

CI secrets/vars needed: `RUNTIME_INGEST_KEY` (secret), `PERKOS_API_URL` (var),
`FIREBASE_WEB_API_KEY` (var). The behavior test no longer takes a long-lived
token: it mints a short-lived Firebase custom token via
`POST /internal/runtimes/test-credentials` (API-key authed, for the dedicated
`BEHAVIOR_TEST_WALLET` service identity) and exchanges it to a ~1h ID token
with `signInWithCustomToken` at run time.

Follow-up: mark the ephemeral `bt-*` agent so the API curator never hibernates
it mid-test (today the script's explicit DELETE teardown handles cleanup).

### Hermes — BYOK OpenAI fix: explicit `api_mode: chat_completions`

`images/hermes/config/hermes.template.yaml`: added `api_mode:
chat_completions` to the model block. Hermes' `runtime_provider.py`
auto-detects the wire protocol from the base_url host, and **any**
`api.openai.com` URL is forced to `codex_responses` (the OpenAI Responses
API, which expects a Codex/OAuth auth profile, not a plain api_key bearer →
401 "missing bearer"). An explicit `api_mode` on a `provider: custom` block
is honored (`_provider_supports_explicit_api_mode`) and SKIPS that
auto-detect, so the api_key reaches `Authorization: Bearer` on
`POST /v1/chat/completions`. `chat_completions` is also what the PerkOS
gateway (api.llm.perkos.xyz, kimi) resolves to, so it's correct for both.
A future GPT-5.x-reasoning BYOK model would want `codex_responses` + a Codex
auth profile (out of scope). **Requires an ECR image rebuild** to ship.
(OpenClaw's equivalent BYOK fix is provision-side — see PerkOS-API — and
needs no image change.)

### Hermes — fix s6 boot regression (exit 127) + open-source skills install

`images/hermes/docker-entrypoint.sh`: upstream Hermes turned
`docker/entrypoint.sh` into a deprecated shim that dies with
`s6-setuidgid: not found` (exit 127) outside the s6 tree, so the old
`PERKOS_BYPASS_S6=true` path crash-looped on Fargate. The image's real
entrypoint is `/init` (s6-overlay), which runs the CMD as its main
program via `/opt/hermes/docker/main-wrapper.sh` (activates the venv,
drops to uid 10000). Fix: our entrypoint does config/SOUL/skills setup
then `exec /init <main-wrapper.sh> gateway run`. Verified live —
api_server binds :8642 again. `PERKOS_BYPASS_S6` is now ignored.

### Both runtimes — install open-source skills at boot

`images/{openclaw,hermes}/docker-entrypoint.sh` decode a base64 JSON list
of `{name,url}` from `PERKOS_AGENT_SKILLS_B64` and fetch each `SKILL.md`
into the agent's skills dir (OpenClaw `<workspace>/skills` via a node
helper, Hermes `$HERMES_HOME/skills` via python3, after the hibernation
restore). Hardening: host allow-list (`raw.githubusercontent.com`)
re-checked in both entrypoints, name sanitized to `[a-z0-9-]`, no redirect
following, `O_NOFOLLOW` + realpath guard vs snapshot-planted symlinks,
256KB/40-count/15s caps, degrade-not-crash. Smoke tests cover positive
install + non-allow-listed skip + SSRF/metadata block.

## 2026-05-29

### Hermes — persist PerkOS Assistant SOUL across container rebuilds

`images/hermes/docker-entrypoint.sh` now copies the baked
`/opt/perkos-assistant/SOUL.md` (concatenated with every `runbook/*.md`)
into `$HERMES_HOME/SOUL.md` on boot, but **only** when the container is
provisioned as `PERKOS_AGENT_NAME=PerkOS-Assistant`. Other Hermes agents
keep their default persona untouched.

Why: the rich PerkOS Assistant prompt + runbook lives at
`/opt/perkos-assistant/` inside the image but Hermes reads its system prompt
from `$HERMES_HOME/SOUL.md` (default `/opt/data/`), which is ephemeral
container state. Before this change, a rebuild dropped the Assistant back to
upstream's generic Hermes persona until someone hot-patched the file by hand.
Now the canonical SOUL is restored on every boot.

Also pulled the current production SOUL from the live `perkos-assistant`
container on the LLM VPS (`46.225.62.30`) and committed it as the repo's
canonical version at `images/hermes/perkos-assistant/SOUL.md` (74 → 578 lines).
The runbook files in the repo already matched production line-for-line.

No image rebuild is forced by this change — the running Assistant continues
to use its hot-patched `/opt/data/SOUL.md`. The new entrypoint logic takes
over at the next natural `perkos-hermes` image release.
