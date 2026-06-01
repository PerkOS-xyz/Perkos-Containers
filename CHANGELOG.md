# Changelog

All notable changes to PerkOS-Containers are recorded here.

Format: one section per release / notable change, newest first. Each entry
captures *what shipped* and the *why* — the equivalent of a good commit body,
collected here so operators don't have to spelunk `git log`. Tag-style
versions are optional; date-stamped sections are fine for in-flight work.

## 2026-06-01

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
