# PerkOS-Containers

Pre-built runtime images that **PerkOS infra** (AWS ECS Fargate) launches
for users who pick "Deploy on PerkOS" in the agent wizard. The images
boot in ~30 seconds because everything is baked in — no build, no plugin
install, no DNS-discovery dance.

Two images, each wrapping a third-party runtime with a PerkOS config
preamble. We **do not fork** the upstream runtimes — we layer config +
entrypoint on top so we can chase upstream releases by bumping a tag.

```
images/
├── openclaw/   FROM ghcr.io/openclaw/openclaw:<pinned>
│                + entrypoint that templates ~/.openclaw/openclaw.json
│                  from env vars, defaults to PerkOS-LLM provider
└── hermes/     FROM nousresearch/hermes-agent:<pinned>
                 + entrypoint that templates ~/.hermes/profiles/<name>/
                   config.yaml + installs hermes-perkos plugin

tasks/          ECS task definition templates (Fargate). Pair the
                runtime image with the perkos-a2a sidecar that bridges
                inbound A2A traffic from transport.perkos.xyz.

.github/        Build + push to AWS ECR on every push to main.
```

## Why two images per runtime?

The runtime container (OpenClaw/Hermes) runs the model + tools. The
**`perkos-a2a` sidecar** terminates the wss connection to
`transport.perkos.xyz`, handles pairing, and forwards inbound tasks to
the runtime over loopback. Splitting them means:

- The runtime image only depends on its upstream
- The bridge image upgrades independently when the A2A protocol evolves
- ECS auto-restarts each side without touching the other

## Image tags

```
<account>.dkr.ecr.us-east-1.amazonaws.com/perkos-openclaw:<runtime-version>-perkos.<n>
<account>.dkr.ecr.us-east-1.amazonaws.com/perkos-hermes:<runtime-version>-perkos.<n>
```

`<runtime-version>` follows the upstream tag (e.g. `2026.5.20` for
OpenClaw). `perkos.<n>` increments when we change anything in the
wrapper (entrypoint, defaults, baseline config).

The currently "pinned" tag — what the admin UI is using right now —
lives in Firestore `config/runtime_images`. The admin rolls forward
or back from `/admin/runtimes`.

## Local testing

```bash
cd images/openclaw
docker build -t perkos-openclaw:dev .
docker run --rm -it \
  -e PERKOS_AGENT_ID=ag_local \
  -e PERKOS_LLM_API_KEY=$PERKOS_LLM_API_KEY \
  -p 18789:18789 \
  perkos-openclaw:dev
```
