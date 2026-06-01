#!/bin/sh
# PerkOS-OpenClaw entrypoint.
#
# Materializes /opt/perkos/openclaw.template.json into
# $OPENCLAW_CONFIG_PATH (default ~/.openclaw/openclaw.json) by substituting
# __FOO__ placeholders with the matching $FOO env var. Refuses to start
# if a required var is unset, since OpenClaw would silently fall back to
# its built-in defaults — which on PerkOS infra means "no LLM source" and
# the agent would loop on `429 No provider configured`.
#
# After templating, exec into the upstream CMD (passed in by Dockerfile).

set -eu

CONFIG_DIR="$(dirname "$OPENCLAW_CONFIG_PATH")"
mkdir -p "$CONFIG_DIR"

# Generate a gateway API key on first boot if not provided. Persisted in
# the config dir so container restarts reuse the same key (otherwise any
# other process talking to this gateway would lose connection).
if [ -z "${PERKOS_GATEWAY_API_KEY:-}" ]; then
  GATEWAY_KEY_FILE="$CONFIG_DIR/.gateway-api-key"
  if [ -f "$GATEWAY_KEY_FILE" ]; then
    PERKOS_GATEWAY_API_KEY="$(cat "$GATEWAY_KEY_FILE")"
  else
    PERKOS_GATEWAY_API_KEY="gk_$(tr -dc 'a-f0-9' < /dev/urandom | head -c 48)"
    printf '%s' "$PERKOS_GATEWAY_API_KEY" > "$GATEWAY_KEY_FILE"
    chmod 600 "$GATEWAY_KEY_FILE"
  fi
  export PERKOS_GATEWAY_API_KEY
fi

# Required vars — fail fast.
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

# Normalize per-gateway *_ENABLED env vars (set by perkos-app's
# ecsProvision when the wallet enables that gateway in /agents/new)
# into the strict "true" / "false" strings the template substitution
# expects. Accept the same truthy values the catalog declares.
truthy() {
  case "${1:-}" in
    true|TRUE|True|1|yes|YES|Yes) echo true ;;
    *) echo false ;;
  esac
}

TELEGRAM_PLUGIN_ENABLED=$(truthy "${TELEGRAM_ENABLED:-}")
SLACK_PLUGIN_ENABLED=$(truthy "${SLACK_ENABLED:-}")
DISCORD_PLUGIN_ENABLED=$(truthy "${DISCORD_ENABLED:-}")

# Substitute __FOO__ placeholders. jq is in the image already.
#
# Plugin enabled flags are substituted as STRINGS first and then
# coerced to JSON booleans in a second pass — gsub only operates on
# strings, but the openclaw plugin config requires a real `true`/
# `false`, not the literal string "true". Two-step pattern is
# simpler than mixing jq filter modes mid-pipeline.
jq \
  --arg agent_id    "$PERKOS_AGENT_ID" \
  --arg agent_name  "$PERKOS_AGENT_NAME" \
  --arg base_url    "$PERKOS_LLM_BASE_URL" \
  --arg api_key     "$PERKOS_LLM_API_KEY" \
  --arg model       "$PERKOS_LLM_DEFAULT_MODEL" \
  --arg gateway_key "$PERKOS_GATEWAY_API_KEY" \
  --arg telegram_plugin_enabled "$TELEGRAM_PLUGIN_ENABLED" \
  --arg slack_plugin_enabled    "$SLACK_PLUGIN_ENABLED" \
  --arg discord_plugin_enabled  "$DISCORD_PLUGIN_ENABLED" \
  '
  (..|strings) |= (
    gsub("__PERKOS_AGENT_ID__";       $agent_id)
    | gsub("__PERKOS_AGENT_NAME__";   $agent_name)
    | gsub("__PERKOS_LLM_BASE_URL__"; $base_url)
    | gsub("__PERKOS_LLM_API_KEY__";  $api_key)
    | gsub("__PERKOS_LLM_DEFAULT_MODEL__"; $model)
    | gsub("__PERKOS_GATEWAY_API_KEY__";   $gateway_key)
  )
  ' /opt/perkos/openclaw.template.json > "$OPENCLAW_CONFIG_PATH"

chmod 600 "$OPENCLAW_CONFIG_PATH"

echo "perkos-entrypoint: wrote $OPENCLAW_CONFIG_PATH (agent=$PERKOS_AGENT_NAME id=$PERKOS_AGENT_ID)"
echo "perkos-entrypoint: channel plugins — telegram=$TELEGRAM_PLUGIN_ENABLED slack=$SLACK_PLUGIN_ENABLED discord=$DISCORD_PLUGIN_ENABLED"

# Persona from env (PerkOS template SOUL).
#
# The provisioner base64's the chosen template's rendered markdown into
# PERKOS_AGENT_SOUL_B64. OpenClaw reads AGENTS.md from the workspace
# root as the agent's standing instructions, so decode it there. The
# template config sets agents.defaults.workspace; mirror that path
# here (default ~/.openclaw/workspace). Absent → default persona.
if [ -n "${PERKOS_AGENT_SOUL_B64:-}" ]; then
  WORKSPACE_DIR="${OPENCLAW_WORKSPACE:-$CONFIG_DIR/workspace}"
  mkdir -p "$WORKSPACE_DIR"
  if printf '%s' "$PERKOS_AGENT_SOUL_B64" | base64 -d > "$WORKSPACE_DIR/AGENTS.md" 2>/dev/null; then
    echo "perkos-entrypoint: persona AGENTS.md written from PERKOS_AGENT_SOUL_B64 ($(wc -c < "$WORKSPACE_DIR/AGENTS.md") bytes) at $WORKSPACE_DIR"
  else
    echo "perkos-entrypoint: WARNING failed to decode PERKOS_AGENT_SOUL_B64 — using default persona"
  fi
fi

# Open-source skills (PerkOS skill packs the wallet selected in the wizard).
#
# The provisioner base64's a JSON list of { name, url } into
# PERKOS_AGENT_SKILLS_B64; each url is a raw SKILL.md the server already
# resolved + allow-list filtered. OpenClaw auto-discovers every
# <workspace>/skills/<name>/SKILL.md (the config sets no skills filter), so
# dropping the files is enough — no config patch needed.
#
# Hardening (a SKILL.md is injected into the system prompt — prompt-injection
# vector): a node helper (1) re-checks each url host against a hard-coded
# allow-list, (2) sanitizes `name` to [a-z0-9-] so it can't escape the skills
# dir, (3) caps file size, (4) writes only to <skillsdir>/<name>/SKILL.md, and
# (5) never aborts the boot on a failed fetch.
if [ -n "${PERKOS_AGENT_SOUL_B64:-}" ] || [ -n "${PERKOS_AGENT_SKILLS_B64:-}" ]; then
  WORKSPACE_DIR="${OPENCLAW_WORKSPACE:-$CONFIG_DIR/workspace}"
fi
if [ -n "${PERKOS_AGENT_SKILLS_B64:-}" ]; then
  echo "perkos-entrypoint: installing selected skill packs..."
  PERKOS_SKILLS_DIR="$WORKSPACE_DIR/skills" \
  node -e '
    const fs = require("fs"), path = require("path"), https = require("https");
    // Host allow-list — keep in sync with the server resolver + Hermes entrypoint.
    const ALLOWED = new Set(["raw.githubusercontent.com"]);
    const MAX = 256 * 1024;
    fs.mkdirSync(process.env.PERKOS_SKILLS_DIR, { recursive: true });
    const dir = fs.realpathSync(process.env.PERKOS_SKILLS_DIR);
    let entries;
    try { entries = JSON.parse(Buffer.from(process.env.PERKOS_AGENT_SKILLS_B64, "base64").toString("utf8")); }
    catch (e) { console.log("perkos-entrypoint: bad PERKOS_AGENT_SKILLS_B64 ("+e.message+") — skipping"); process.exit(0); }
    if (!Array.isArray(entries)) { console.log("perkos-entrypoint: skills payload not a list — skipping"); process.exit(0); }
    const get = (url) => new Promise((res) => {
      let u; try { u = new URL(url); } catch { return res(null); }
      if (u.protocol !== "https:" || !ALLOWED.has(u.hostname)) return res(null);
      https.get(url, { headers: { "User-Agent": "perkos-entrypoint" }, timeout: 15000 }, (r) => {
        if (r.statusCode !== 200) { r.resume(); return res(null); }
        const chunks = []; let len = 0;
        r.on("data", (c) => { len += c.length; if (len <= MAX + 1) chunks.push(c); });
        r.on("end", () => res(len > MAX ? null : Buffer.concat(chunks)));
      }).on("error", () => res(null)).on("timeout", function () { this.destroy(); res(null); });
    });
    (async () => {
      let n = 0;
      for (const ent of entries.slice(0, 40)) {
        const name = String((ent && ent.name) || "").toLowerCase().replace(/[^a-z0-9-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 64);
        const url = String((ent && ent.url) || "");
        if (!name) continue;
        const data = await get(url);
        if (!data) { console.log("perkos-entrypoint: skill \""+name+"\" not fetched (host not allowed / failed) — skipped"); continue; }
        const dest = path.join(dir, name);
        try {
          fs.mkdirSync(dest, { recursive: true });
          // Guard vs a snapshot-planted symlink redirecting the write: dest
          // must stay inside the skills dir, and O_NOFOLLOW refuses a symlink
          // at SKILL.md.
          if (fs.realpathSync(dest) !== path.join(dir, name)) { console.log("perkos-entrypoint: skill \""+name+"\" path escapes skills dir — skipped"); continue; }
          const file = path.join(dest, "SKILL.md");
          try { fs.unlinkSync(file); } catch (e) {}
          const fd = fs.openSync(file, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_NOFOLLOW | fs.constants.O_TRUNC, 0o644);
          fs.writeSync(fd, data); fs.closeSync(fd); n++;
          console.log("perkos-entrypoint: skill written "+name+"/SKILL.md ("+data.length+" bytes)");
        } catch (e) { console.log("perkos-entrypoint: skill write failed ("+e.message+") — continuing"); }
      }
      console.log("perkos-entrypoint: installed "+n+" skill pack file(s)");
    })();
  ' || echo "perkos-entrypoint: skill install step failed (continuing)"
fi

exec "$@"
