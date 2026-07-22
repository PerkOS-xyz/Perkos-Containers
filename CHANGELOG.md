# Changelog

All notable changes to PerkOS-Containers are recorded here.

Format: one section per release / notable change, newest first. Each entry
captures *what shipped* and the *why* — the equivalent of a good commit body,
collected here so operators don't have to spelunk `git log`. Tag-style
versions are optional; date-stamped sections are fine for in-flight work.

## 2026-07-22

### OpenClaw container healthcheck port alignment

The OpenClaw image now exposes and probes port `3000`, matching the rendered
gateway configuration, ECS provisioner, and A2A bridge target. The previous
upstream-default `18789` probe marked a working gateway unhealthy and could
cause needless ECS task replacement. The OpenClaw smoke suite now asserts both
the exposed port and healthcheck target.

### Fast conversational path for managed channels

Hermes and OpenClaw agents now receive a stable PerkOS-managed instruction to
answer simple definitions, greetings, rewrites, summaries, and explicitly brief
questions directly without launching unnecessary research or tool loops. Tools
remain available for actions, verification, current information, requested
sources, and genuinely missing context, so autonomous project work keeps its
full capability and turn budget.

Hermes also suppresses upstream lifecycle broadcasts on Telegram, Slack, and
Farcaster. Routine ECS replacement or test teardown no longer posts the
misleading “Your current task will be interrupted” warning after a completed
turn. Telegram retains its native typing indicator while permanent interim,
tool-progress, and streaming messages remain disabled. OpenClaw installs the
same marked policy block into every primary and co-resident `AGENTS.md` after
snapshot restoration, replacing the managed block idempotently without
overwriting user personas.

## 2026-07-21

### Hermes messaging loop protection

Telegram now delivers only the final assistant response: token streaming,
tool-progress bubbles, and interim assistant commentary are disabled for that
surface, while long-running heartbeat notifications remain enabled. Hermes
agent requests also receive a configurable `PERKOS_AGENT_MAX_TURNS` budget
(default `30`, validated as a positive integer) instead of inheriting the
upstream 90-turn default. This bounds malformed provider/tool combinations and
prevents permanent Telegram progress-message spam. The guard was added after
an invalid nested OpenClaw → Hermes-agent provider test retried missing Hermes
tools hundreds of times from one inbound Telegram message.

## 2026-06-21

### Skill id rename: `perkos-tech` → `perkos-knowledge` (both runtimes)

Completes the PerkOS Knowledge plugin rebrand inside the images. The bundled
plugin's internal id was the last `perkos-tech` holdover (the tool names were
already `perkos_knowledge_*`). Renamed the vendored copies and every reference
so a freshly built image loads the plugin under `perkos-knowledge`:

- **Hermes** — `images/hermes/plugins/perkos-tech` → `plugins/perkos-knowledge`
  (folder + `plugin.yaml` `name` + the nine `toolset=` ids in `__init__.py`); the
  Dockerfile `COPY`, the entrypoint staging (`/opt/perkos-plugins/...` →
  `$HERMES_HOME/plugins/...`), and the gateway allow-list
  (`plugins.enabled: [perkos-knowledge]` in `hermes.template.yaml`) all moved in
  lockstep — they must match or the standalone plugin won't load.
- **OpenClaw** — `images/openclaw/skills/perkos-tech` → `skills/perkos-knowledge`
  (folder + `SKILL.md` `name` + helper paths). The Dockerfile copies `skills/`
  wholesale into `/opt/perkos-skills` and the entrypoint stages every folder
  generically, so nothing else needed to change.

Self-contained per image and **non-breaking**: nothing outside the image (no
provisioning code, no agent soul) references the skill id, and already-running
agents keep their existing image tag. Helper script filenames
(`perkos_tech.mjs`/`.py`) are unchanged. Upstream source + npm:
`@perkos/perkos-knowledge-plugin@0.3.0` (the old `@perkos/perkos-tech-plugin` is
deprecated, pointing here).

## 2026-06-04

### Hibernation state snapshot/restore — Hermes VALIDATED e2e, OpenClaw generalized

The "clone the agent's filesystem on hibernate, restore it on wake" mechanism
now works. Client-side **envelope encryption**: a KMS data key (encryption
context `agent=<id>`) encrypts a gzip tar of the state dir with openssl
**AES-256-CBC + PBKDF2**; S3 only ever stores ciphertext + the wrapped key +
a plaintext manifest. **Trigger = periodic loop** (`PERKOS_SNAPSHOT_INTERVAL_SEC`,
default 300s) backgrounded by the entrypoint before it hands off to the runtime
(the s6/tini shutdown hooks were unreliable); **restore.sh runs on every boot**
(no-op on first launch). Generic `snapshot.sh`/`restore.sh` shared verbatim by
both images (`SRC`/`DEST` default to `HERMES_HOME`/`OPENCLAW_HOME`; `PERKOS_RUNTIME`
tunes excludes + manifest). Keep-last-N prune (`PERKOS_BACKUP_RETENTION`, default 5).

- **Hermes — VALIDATED end-to-end on live ECS.** Image `latest-perkos.2026.06.04.947ce24`:
  full launch → encrypted snapshot → S3 (3 objects, 7 MB manifest
  `alg:"AES-256-CBC+PBKDF2"`) → hibernate (`0/0`) → wake → `[restore] restore
  complete` (7,124,619 B back into `/opt/data`). Proves KMS `GenerateDataKey`,
  client-encrypt + S3 `PutObject` under the task role, and the wake restore path.
- **CI green (3 smoke fixes that were masking each other behind `fail()`'s
  `exit 1`):** `API_SERVER_KEY=dummy` in the smoke env (the api_server refuses
  to boot without it); the snapshot no-op grep tolerates compact JSON
  (`"skipped":true`); and the config check asserts the **inline `api_key:`**
  (the BYOK-401 fix) instead of the stale `api_key_env` binding.
- **OpenClaw — generalized (code; pending build + e2e).** `images/openclaw/`
  now bakes `snapshot.sh`/`restore.sh` (identical to Hermes) + installs
  `bash`/`openssl`/`ca-certificates`/`awscli`; the tini entrypoint exports
  `PERKOS_STATE_DIR=$OPENCLAW_HOME`, runs restore-on-boot (after the persona/
  bundled-skill writes, before the open-source skill fetch so fresh skills win),
  and backgrounds the periodic snapshot loop before `exec "$@"`. New smoke checks
  assert the scripts are baked + executable, the AWS CLI is present, and the
  snapshot no-op contract holds.
- **Restore-from-specific — one-shot S3 directive** (`f0ae6f4`, both runtimes).
  For point-in-time restore from the Settings → Backups UI: the API writes the
  chosen timestamp to `<prefix>restore-directive`; on the next boot `restore.sh`
  reads it (precedence over latest), restores that snapshot, then **deletes the
  directive** so it applies exactly once. Baking `PERKOS_RESTORE_TS` into the
  persistent task-def env instead would re-restore the same ts on every restart,
  silently reverting newer work. `PERKOS_RESTORE_TS` still works for ad-hoc use;
  the ts is sanitized (`tr -dc A-Za-z0-9`) before use.
- **Hardened by a pre-deploy adversarial review** (`61a0680`). Two HIGH + one
  MEDIUM defect fixed before this ever reached ECR: (1) `snapshot.sh` now
  EXCLUDES the entrypoint-rendered config (hermes `./config.yaml`; openclaw
  `./openclaw.json` + `./.gateway-api-key`) — restore was clobbering the fresh,
  env-derived config (inline LLM key; OpenClaw gateway token) with the snapshot's
  STALE copy, an unconditional 401 after a re-provision/resilient wake that minted
  new keys; (2) a directive pointing at a since-pruned ts (TOCTOU during the
  deploy window) used to skip without deleting the directive or falling back →
  agent ran blank forever; now it drops the dead directive and restores latest;
  (3) the directive delete is retried (transient S3 error would otherwise
  re-restore the same ts next boot).

## 2026-06-02

### OpenClaw — unblock BYOK tool execution (thinkingDefault off + memorySearch off)

`images/openclaw/config/openclaw.template.json` `agents.defaults` gained
`thinkingDefault: "off"` and `memorySearch.enabled: false`. Two BYOK-gpt-4o
blockers seen live: (1) OpenClaw spawned a tool-execution **subagent** with
thinking `"minimal"`, which `byok/gpt-4o` rejects (`Thinking level "minimal"
is not supported … Use one of: off`) → the subagent died and `createTask`
never ran (job board stayed empty though the model narrated creating tasks).
`thinkingDefault: "off"` is read by `resolveThinkingDefault` for the agent
AND subagents, so no unsupported level is requested. (2) OpenClaw's memory
search bootstrap is hardcoded to provider `openai`; with our provider named
`byok` it errored `No API key found for provider "openai"` on every turn
(noise + the model believed it couldn't access context). Disabling memory
search removes the broken-for-BYOK feature; re-enable later with a real
embeddings provider. Both defaults are safe for the gateway/kimi path too.

### Fix: bump A2A pin 0.12.0 → 0.12.7 (multi-agent reply loop regression)

`build-push-ecr.yml` env + `images/perkos-a2a-bridge/Dockerfile` ARG pinned
`PERKOS_A2A_VERSION=0.12.0`, which only added the `A2A_HERMES_AUTO_REPLY`
flag — the reply loop itself only works from 0.12.5+ (`0.12.5` task_response
carries the real runtime text, `0.12.6` raises the local-task wait 45s→240s,
`0.12.7` short-circuits the A2A runtime prompt when auto-reply is on). 0.12.0
regressed live multi-agent behavior: chat turns returned "No response from
OpenClaw" and A2A tasks returned the queued-artifact placeholder with
platform-tools not firing. Bumped both to **0.12.7** (keeps the auto-reply
flag, restores the fixes). `deploy/perkos-assistant/docker-compose.yml` should
be bumped to 0.12.7 too for lockstep. Found while re-running the real-agent
orchestration test on BYOK gpt-4o images.

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
