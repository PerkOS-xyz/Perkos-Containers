# Changelog

All notable changes to PerkOS-Containers are recorded here.

Format: one section per release / notable change, newest first. Each entry
captures *what shipped* and the *why* — the equivalent of a good commit body,
collected here so operators don't have to spelunk `git log`. Tag-style
versions are optional; date-stamped sections are fine for in-flight work.

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
