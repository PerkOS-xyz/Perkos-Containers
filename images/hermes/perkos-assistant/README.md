# PerkOS Assistant — content baked into the Hermes image

Source of truth: `PerkOS-xyz/PerkOS` repo at `docs/perkos-assistant/`. This directory is a **manual copy** that gets COPYed into the Hermes container at build time and lands at `/opt/perkos-assistant/`.

## Why a copy

For v1 we keep it dumb:
- The PerkOS-Containers Docker build can't read across repos at build time without CI complexity (cross-repo checkouts, branch coordination, secrets for private repos if it ever becomes private)
- The Assistant container is the unit we ship; everything it needs to boot lives in this repo
- A future sync script (or GitHub Action that opens a PR in this repo when the source changes) can automate the copy — but it's not load-bearing today

## How to update

When the source changes in `PerkOS/docs/perkos-assistant/`, mirror the edit here and open a PR:

```bash
cd /path/to/PerkOS-App
cp PerkOS/docs/perkos-assistant/SOUL.md \
   PerkOS-Containers/images/hermes/perkos-assistant/SOUL.md
cp -r PerkOS/docs/perkos-assistant/runbook/. \
      PerkOS-Containers/images/hermes/perkos-assistant/runbook/
```

The CI build picks it up automatically (any change under `images/**` triggers a rebuild + ECR push).

## Layout (inside the container)

```
/opt/perkos-assistant/
├── README.md           # this file
├── SOUL.md             # 8-section persona, becomes the Assistant system prompt
└── runbook/
    ├── 00-platform-overview.md
    ├── 01-deploy-modes.md
    ├── 02-runtime-choices.md
    ├── 03-llm-options.md
    ├── 04-lifecycle.md
    └── 05-allowlist-and-escalation.md
```

The `perkos-platform-tools` Hermes skill (sibling directory) reads these files at runtime to answer user questions.
