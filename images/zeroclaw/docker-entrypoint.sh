#!/bin/bash
# PerkOS-ZeroClaw entrypoint.
#
# Renders ~/.zeroclaw/config.toml from PERKOS_* env vars, then execs the
# upstream binary. Fails fast on a missing required var rather than letting the
# agent boot with no LLM source and loop on provider errors.
#
# WHY WE DRIVE THE BINARY INSTEAD OF TEMPLATING TOML
# The other two images substitute a checked-in template (jq / envsubst). We
# can't here: ZeroClaw ENCRYPTS secrets at rest (`api_key = "enc2:…"`) with its
# own key management, so a hand-written plaintext TOML would either be rejected
# or would persist the LLM key in clear. `zeroclaw config set <path> <value>`
# does the encryption for us and validates against the real schema.
#
# THE --no-interactive TRAP: without that flag, `config set` on any secret field
# aborts with "Secret input requires a terminal on stdin and stderr" — there is
# no TTY in ECS, so provisioning would be impossible. Every set below passes it.
#
# THE PAIRING TRAP: the gateway normally prints a one-time pairing code and
# refuses authenticated routes until a client exchanges it via POST /pair. That
# is unusable for automated provisioning. Pre-seeding `gateway.paired_tokens`
# makes it boot already paired (it logs "Pairing: ACTIVE"), which is the same
# trick the OpenClaw entrypoint uses with PERKOS_GATEWAY_API_KEY.
#
# THE risk_profile TRAP (cost us the whole P0 spike): an agent whose
# `risk_profile` does not name a configured `[risk_profiles.<alias>]` entry
# still BOOTS, and every message then fails with the generic, deeply misleading
# `500 {"error":"LLM request failed"}` — the LLM is never even called. Always
# create the profile and reference it.
#
# Required env:
#   - PERKOS_AGENT_ID
#   - PERKOS_AGENT_NAME
#   - PERKOS_LLM_API_KEY
#
# Optional:
#   - PERKOS_HIBERNATION_S3_URI / _KMS_KEY   restore on boot + periodic snapshot
#   - PERKOS_AGENT_SOUL_B64                  persona (OpenClaw-format identity)
#   - PERKOS_AGENT_SKILLS_B64                selected skill packs
#   - PERKOS_GATEWAY_API_KEY                 pre-set gateway bearer (else minted)

set -eu

require() {
  eval "val=\${$1:-}"
  if [ -z "$val" ]; then
    echo "perkos-entrypoint: required env $1 is not set" >&2
    exit 1
  fi
}
require PERKOS_AGENT_ID
require PERKOS_AGENT_NAME
require PERKOS_LLM_API_KEY

ZC_HOME="${HOME:-/zeroclaw-data}"
CONFIG_DIR="$ZC_HOME/.zeroclaw"
# The alias MUST be the one the gateway routes to. Upstream bakes an agent
# called `default` into the image and `POST /webhook` dispatches to it; a
# freshly created alias (e.g. `main`) is configured perfectly and then simply
# never receives traffic, so the agent answers every message with the generic
# `LLM request failed` while `zeroclaw doctor` reports the provider healthy.
ALIAS="${PERKOS_ZEROCLAW_AGENT_ALIAS:-default}"
PROVIDER_PATH="providers.models.custom.perkos"
RISK_PROFILE="perkos"
mkdir -p "$CONFIG_DIR"

# Hibernation operates on the whole ZeroClaw home: config dir + data dir
# (SQLite memory, sessions, knowledge).
export PERKOS_STATE_DIR="$ZC_HOME"
export PERKOS_RUNTIME=zeroclaw

# `config set` is the only supported non-interactive writer. Wrap it so a single
# failing key is loud but doesn't abort the boot half-configured.
zc() { zeroclaw "$@"; }
zcset() {
  if ! zc config set "$1" "$2" --no-interactive >/dev/null 2>&1; then
    echo "perkos-entrypoint: WARNING failed to set $1" >&2
    return 1
  fi
  return 0
}
# Fail-fast variant for the keys without which the agent is a healthy-looking
# no-op: the gateway boots and passes its healthcheck even with no provider
# wired, so a silent failure here would ship a container that 500s on every
# message. Better to crash-loop visibly and let ECS surface it.
zcset_required() {
  if ! zcset "$1" "$2"; then
    echo "perkos-entrypoint: FATAL could not set required key $1 — refusing to boot a non-functional agent" >&2
    exit 1
  fi
}

# ── Schema migration (must precede every config write) ───────────────────────
# The upstream image BAKES a config.toml at an older schema_version, and
# ZeroClaw hard-refuses to touch a stale config:
#   "config at …/config.toml is schema_version 1; run `zeroclaw config migrate`"
# Every `config init`/`config set` below would fail with rc=1, and because the
# gateway still boots on the old config the container would come up "healthy"
# while answering with no provider at all. `config migrate` is idempotent
# ("Config already at current schema version", rc=0) so it is safe on every
# boot, including after a snapshot restore of an older config.
if ! zeroclaw config migrate 2>&1 | sed 's/^/perkos-entrypoint: [migrate] /'; then
  echo "perkos-entrypoint: WARNING config migrate failed — config writes may be rejected" >&2
fi

# ── Gateway bearer token ─────────────────────────────────────────────────────
# Persisted next to the config so a container restart reuses the same token —
# otherwise the bridge sidecar's stored bearer would stop matching after every
# bounce. Same contract as OpenClaw's .gateway-api-key.
if [ -z "${PERKOS_GATEWAY_API_KEY:-}" ]; then
  TOKEN_FILE="$CONFIG_DIR/.gateway-token"
  if [ -f "$TOKEN_FILE" ]; then
    PERKOS_GATEWAY_API_KEY="$(cat "$TOKEN_FILE")"
  else
    PERKOS_GATEWAY_API_KEY="zcl_live_$(tr -dc 'a-f0-9' < /dev/urandom | head -c 40)"
    printf '%s' "$PERKOS_GATEWAY_API_KEY" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
  fi
  export PERKOS_GATEWAY_API_KEY
fi

# ── LLM provider ─────────────────────────────────────────────────────────────
# The `custom` family + kind=openai-compatible + wire_api=chat_completions is
# what our Ollama-backed gateway speaks, and is also correct for a BYOK
# OpenAI-compatible endpoint. NOTE the field is `uri` (the full endpoint root),
# NOT `base_url` — ZeroClaw has no base_url on a model provider.
# BYOK against api.openai.com proper would want wire_api=responses; expose the
# knob rather than hard-coding, mirroring the BYOK escape hatch the other two
# runtimes have.
WIRE_API="${PERKOS_LLM_WIRE_API:-chat_completions}"

zc config init "$PROVIDER_PATH" >/dev/null 2>&1 || true
zcset_required "$PROVIDER_PATH.uri"      "$PERKOS_LLM_BASE_URL"
zcset_required "$PROVIDER_PATH.model"    "$PERKOS_LLM_DEFAULT_MODEL"
zcset_required "$PROVIDER_PATH.wire_api" "$WIRE_API"
zcset_required "$PROVIDER_PATH.kind"     "openai-compatible"
zcset_required "$PROVIDER_PATH.api_key"  "$PERKOS_LLM_API_KEY"

# ── Risk profile (see the trap note in the header) ───────────────────────────
# Defaults are deliberately conservative upstream (level=supervised,
# workspace_only=true, an auto_approve allow-list of read-only tools). We keep
# them: a PerkOS-managed agent has no business reaching outside its workspace.
zc config init "risk_profiles.$RISK_PROFILE" >/dev/null 2>&1 || true

# ── Agent alias ──────────────────────────────────────────────────────────────
# `agents create` errors when the alias already exists (restart / restored
# state), which is not a failure for us.
zc agents create "$ALIAS" >/dev/null 2>&1 || true
zcset_required "agents.$ALIAS.model_provider" "custom.perkos"
zcset_required "agents.$ALIAS.risk_profile"   "$RISK_PROFILE"

# ── Memory ───────────────────────────────────────────────────────────────────
# The sqlite backend defaults to search_mode=hybrid, which warns on every boot
# because we ship no embedding provider and silently degrades to keyword search.
# Ask for the keyword mode explicitly so the behavior is intentional, not a
# fallback. Wiring a real embedder is a follow-up.
zcset "memory.search_mode" "bm25" || true

# ── Gateway ──────────────────────────────────────────────────────────────────
# Bind on the container interface (not upstream's 127.0.0.1 default) so the
# bridge sidecar can reach it by service name. allow_public_bind is upstream's
# guard against doing that accidentally; the port is never published on the host
# in our compose/task definitions.
zcset "gateway.host" "0.0.0.0"   || true
zcset "gateway.allow_public_bind" "true" || true
zcset "gateway.paired_tokens" "[\"$PERKOS_GATEWAY_API_KEY\"]" || true

echo "perkos-entrypoint: config rendered at $CONFIG_DIR/config.toml (agent=$PERKOS_AGENT_NAME id=$PERKOS_AGENT_ID alias=$ALIAS)"

# ── Persona ──────────────────────────────────────────────────────────────────
# ZeroClaw's per-agent identity block already defaults to format="openclaw", so
# the SOUL markdown the launcher renders drops in unchanged — same artifact the
# OpenClaw image writes to AGENTS.md.
# The identity file is discovered from the agent's OWN workspace
# (.zeroclaw/agents/<alias>/workspace/AGENTS.md) — that is the path the runtime
# scans and the one `zeroclaw doctor` reports on. Writing it to $HOME and only
# pointing `identity.aieos_path` at it is NOT enough: the agent boots, answers,
# and ignores the persona entirely (it introduces itself as a generic
# assistant). We write the file where it is discovered AND set the explicit
# path, so neither mechanism is load-bearing on its own.
AGENT_WORKSPACE="$CONFIG_DIR/agents/$ALIAS/workspace"
if [ -n "${PERKOS_AGENT_SOUL_B64:-}" ]; then
  mkdir -p "$AGENT_WORKSPACE"
  IDENTITY_FILE="$AGENT_WORKSPACE/AGENTS.md"
  if printf '%s' "$PERKOS_AGENT_SOUL_B64" | base64 -d > "$IDENTITY_FILE" 2>/dev/null; then
    # SOUL.md is the personality half of the same OpenClaw-format pair; ship the
    # same content under both names so whichever the runtime prefers is present.
    cp "$IDENTITY_FILE" "$AGENT_WORKSPACE/SOUL.md" 2>/dev/null || true
    zcset "agents.$ALIAS.identity.format"     "openclaw"       || true
    zcset "agents.$ALIAS.identity.aieos_path" "$IDENTITY_FILE" || true
    echo "perkos-entrypoint: persona written to $IDENTITY_FILE ($(wc -c < "$IDENTITY_FILE") bytes)"
  else
    echo "perkos-entrypoint: WARNING failed to decode PERKOS_AGENT_SOUL_B64 — using default persona"
  fi
fi

# ── Bundled PerkOS skills ────────────────────────────────────────────────────
# perkos-platform-tools ships perkos_tools.py, which the model executes to drive
# the job board. Script execution is OFF by default in ZeroClaw
# (skills.allow_scripts=false), so the skill would be inert without this.
SKILLS_DIR="$ZC_HOME/skills"
mkdir -p "$SKILLS_DIR"
if [ -d /opt/perkos-skills ]; then
  for d in /opt/perkos-skills/*/; do
    [ -d "$d" ] || continue
    n=$(basename "$d")
    rm -rf "${SKILLS_DIR:?}/$n"
    cp -r "$d" "$SKILLS_DIR/$n"
  done
  zcset "skills.allow_scripts" "true"      || true
  zcset "skills.open_skills_enabled" "true" || true
  zcset "skills.open_skills_dir" "$SKILLS_DIR" || true
  echo "perkos-entrypoint: bundled skills installed: $(ls "$SKILLS_DIR" 2>/dev/null | tr '\n' ' ')"
fi

# ── Hibernation restore ──────────────────────────────────────────────────────
# No-op on first launch or when PERKOS_HIBERNATION_S3_URI is unset. Runs AFTER
# the config render (the snapshot deliberately excludes config.toml, so the
# env-derived render stays authoritative) and BEFORE the skill-pack fetch, so
# freshly fetched skill content wins over a stale snapshot copy.
echo "perkos-entrypoint: checking for hibernation snapshot..."
/usr/local/bin/perkos-restore.sh || \
  echo "perkos-entrypoint: restore failed (continuing with fresh state)"

# ── Open-source skill packs ──────────────────────────────────────────────────
# Same hardened fetch as the other two entrypoints: host allow-list, no
# redirects, size cap, name sanitized to [a-z0-9-], O_NOFOLLOW write, never
# fatal. A SKILL.md lands in the system prompt, so it is a prompt-injection
# vector and gets treated as untrusted input.
if [ -n "${PERKOS_AGENT_SKILLS_B64:-}" ]; then
  echo "perkos-entrypoint: installing selected skill packs..."
  PERKOS_AGENT_SKILLS_B64="$PERKOS_AGENT_SKILLS_B64" \
  PERKOS_SKILLS_DIR="$SKILLS_DIR" \
  python3 - <<'PYSKILLS' || echo "perkos-entrypoint: skill install step failed (continuing)"
import base64, json, os, re, sys
from urllib.parse import urlparse
from urllib.request import build_opener, HTTPRedirectHandler, Request

ALLOWED_HOSTS = {"raw.githubusercontent.com"}
MAX_BYTES = 256 * 1024
NAME_RE = re.compile(r"[^a-z0-9-]+")

class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None

_opener = build_opener(_NoRedirect)

skills_dir = os.path.realpath(os.environ["PERKOS_SKILLS_DIR"])
try:
    entries = json.loads(base64.b64decode(os.environ["PERKOS_AGENT_SKILLS_B64"]))
except Exception as e:
    print(f"perkos-entrypoint: bad PERKOS_AGENT_SKILLS_B64 ({e}) — skipping")
    sys.exit(0)

if not isinstance(entries, list):
    print("perkos-entrypoint: skills payload not a list — skipping")
    sys.exit(0)

installed = 0
for ent in entries[:40]:
    try:
        name = NAME_RE.sub("-", str(ent.get("name", "")).lower()).strip("-")[:64]
        url = str(ent.get("url", ""))
        if not name:
            continue
        u = urlparse(url)
        if u.scheme != "https" or u.hostname not in ALLOWED_HOSTS:
            print(f"perkos-entrypoint: skill '{name}' url host not allowed — skipped")
            continue
        req = Request(url, headers={"User-Agent": "perkos-entrypoint"})
        with _opener.open(req, timeout=15) as resp:
            if getattr(resp, "status", 200) != 200:
                print(f"perkos-entrypoint: skill '{name}' non-200 — skipped")
                continue
            data = resp.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            print(f"perkos-entrypoint: skill '{name}' too large — skipped")
            continue
        dest_dir = os.path.join(skills_dir, name)
        if os.path.realpath(dest_dir) != os.path.join(skills_dir, name):
            print(f"perkos-entrypoint: skill '{name}' path escapes skills dir — skipped")
            continue
        os.makedirs(dest_dir, exist_ok=True)
        dest_file = os.path.join(dest_dir, "SKILL.md")
        try:
            os.unlink(dest_file)
        except FileNotFoundError:
            pass
        fd = os.open(dest_file, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_TRUNC, 0o644)
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        installed += 1
        print(f"perkos-entrypoint: skill written {name}/SKILL.md ({len(data)} bytes)")
    except Exception as e:
        print(f"perkos-entrypoint: skill fetch failed ({e}) — continuing")

print(f"perkos-entrypoint: installed {installed} skill pack file(s)")
PYSKILLS
fi

# ── Periodic state snapshot ──────────────────────────────────────────────────
# Backgrounded before we hand off to the gateway. No-op unless both the S3 URI
# and the KMS key are set. restore.sh already ran, so the first snapshot
# reflects the restored state.
if [ -n "${PERKOS_HIBERNATION_S3_URI:-}" ] && [ -n "${PERKOS_HIBERNATION_KMS_KEY:-}" ]; then
  (
    while sleep "${PERKOS_SNAPSHOT_INTERVAL_SEC:-300}"; do
      /usr/local/bin/perkos-snapshot.sh >/dev/null 2>&1 || true
    done
  ) &
  echo "perkos-entrypoint: periodic state snapshot enabled (every ${PERKOS_SNAPSHOT_INTERVAL_SEC:-300}s)"
fi

echo "perkos-entrypoint: exec zeroclaw $*"
exec zeroclaw "$@"
