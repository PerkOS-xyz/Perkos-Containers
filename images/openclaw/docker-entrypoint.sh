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

# Hibernation snapshot/restore operate on the whole OpenClaw home — config +
# workspace (AGENTS.md, skills, memory). snapshot.sh/restore.sh default their
# source/target to OPENCLAW_HOME; pin it to the resolved config dir so they
# back up exactly what survives a hibernate→wake clone.
export PERKOS_STATE_DIR="$CONFIG_DIR"

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
TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS:-}"
TELEGRAM_HOME_CHANNEL="${TELEGRAM_HOME_CHANNEL:-}"
SLACK_PLUGIN_ENABLED=$(truthy "${SLACK_ENABLED:-}")
DISCORD_PLUGIN_ENABLED=$(truthy "${DISCORD_ENABLED:-}")
# OpenClaw's bundled workboard (local kanban + agent tools): the agent's
# LOCAL sub-task ledger for decomposing its own work — the PerkOS board stays
# the cross-agent source of truth. Opt-in per agent via the provisioner
# (PERKOS_WORKBOARD_ENABLED=true) because the extra tool schemas cost prompt
# tokens on every turn.
WORKBOARD_PLUGIN_ENABLED=$(truthy "${PERKOS_WORKBOARD_ENABLED:-}")

# Capability toggles. PERKOS_DISABLED_TOOLS is a comma-separated list of the
# built-in capability ids the wallet turned OFF in the wizard's Capabilities
# step (web-search, code-execution, browser, memory). Empty/unset → nothing
# disabled → identical config to before (every built-in tool stays on).
#
# OpenClaw enforces a global tool allow/deny policy where deny wins over allow
# AND over per-plugin enablement, is case-insensitive, and supports wildcards.
# Each capability id maps to the concrete tool ids that back it. We render
# them into .tools.deny below. See docs.openclaw.ai/gateway/config-tools.
DENY_TOOLS=""
add_deny() { for _t in "$@"; do DENY_TOOLS="$DENY_TOOLS $_t"; done; }
_OLDIFS=$IFS
IFS=','
for _cap in ${PERKOS_DISABLED_TOOLS:-}; do
  _cap=$(printf '%s' "$_cap" | tr -d '[:space:]')
  case "$_cap" in
    web-search)      add_deny web_search ;;
    code-execution)  add_deny exec process code_execution ;;
    browser)         add_deny browser ;;
    memory)          add_deny memory_search memory_get ;;
    "")              ;;
    *) echo "perkos-entrypoint: WARNING unknown disabled-tool id '$_cap' — ignored" >&2 ;;
  esac
done
IFS=$_OLDIFS
DENY_TOOLS=$(printf '%s' "$DENY_TOOLS" | sed 's/^ *//; s/ *$//')

# Substitute __FOO__ placeholders. jq is in the image already.
#
# Plugin enabled flags are substituted as STRINGS first and then
# coerced to JSON booleans in a second pass — gsub only operates on
# strings, but the openclaw plugin config requires a real `true`/
# `false`, not the literal string "true". Two-step pattern is
# simpler than mixing jq filter modes mid-pipeline.
# Provider API kind: "ollama" for the PerkOS gateway (default), or
# "openai" when pointed at an OpenAI-compatible endpoint (BYOK). The
# provisioner sets PERKOS_LLM_API; default to ollama for back-compat.
LLM_API="${PERKOS_LLM_API:-ollama}"
# Provider name = the key under models.providers AND the prefix OpenClaw
# strips from `primary` before sending the model id on the wire. Must be
# "ollama" for the gateway; "openai" for a BYOK OpenAI endpoint (so the
# wire model is "gpt-4o", not "ollama/gpt-4o" which 404s).
LLM_PROVIDER="${PERKOS_LLM_PROVIDER:-ollama}"
jq \
  --arg agent_id    "$PERKOS_AGENT_ID" \
  --arg agent_name  "$PERKOS_AGENT_NAME" \
  --arg base_url    "$PERKOS_LLM_BASE_URL" \
  --arg api_key     "$PERKOS_LLM_API_KEY" \
  --arg model       "$PERKOS_LLM_DEFAULT_MODEL" \
  --arg llm_api     "$LLM_API" \
  --arg llm_provider "$LLM_PROVIDER" \
  --arg gateway_key "$PERKOS_GATEWAY_API_KEY" \
  --arg telegram_plugin_enabled "$TELEGRAM_PLUGIN_ENABLED" \
  --arg telegram_allowed_users "$TELEGRAM_ALLOWED_USERS" \
  --arg telegram_home_channel "$TELEGRAM_HOME_CHANNEL" \
  --arg slack_plugin_enabled    "$SLACK_PLUGIN_ENABLED" \
  --arg discord_plugin_enabled  "$DISCORD_PLUGIN_ENABLED" \
  --arg workboard_enabled       "$WORKBOARD_PLUGIN_ENABLED" \
  --arg deny_tools              "$DENY_TOOLS" \
  '
  (..|strings) |= (
    gsub("__PERKOS_AGENT_ID__";       $agent_id)
    | gsub("__PERKOS_AGENT_NAME__";   $agent_name)
    | gsub("__PERKOS_LLM_BASE_URL__"; $base_url)
    | gsub("__PERKOS_LLM_API_KEY__";  $api_key)
    | gsub("__PERKOS_LLM_DEFAULT_MODEL__"; $model)
    | gsub("__PERKOS_LLM_API__";      $llm_api)
    | gsub("__PERKOS_LLM_PROVIDER__"; $llm_provider)
    | gsub("__PERKOS_GATEWAY_API_KEY__";   $gateway_key)
  )
  # The provider object KEY is literally "ollama" in the template (gsub
  # only rewrites string VALUES, not object keys). Rename it to the real
  # provider name when BYOK uses a different one, so it matches the
  # "<provider>/<model>" primary above.
  | if $llm_provider != "ollama"
    then .models.providers |= (with_entries(.key = $llm_provider))
    else . end
  # Telegram is a native OpenClaw channel plugin, configured under
  # channels.telegram (not plugins.entries). The bot token remains in the
  # process environment and is referenced by name so it is never written to
  # openclaw.json. An explicit allowlist switches the safe default from pairing
  # to allowlist mode.
  | if $telegram_plugin_enabled == "true"
    then .channels.telegram = {
      enabled: true,
      botToken: { source: "env", provider: "default", id: "TELEGRAM_BOT_TOKEN" },
      dmPolicy: (if ($telegram_allowed_users | length) > 0 then "allowlist" else "pairing" end)
    }
    | if ($telegram_allowed_users | length) > 0
      then .channels.telegram.allowFrom = (
        $telegram_allowed_users
        | split(",")
        | map(gsub("^\\s+|\\s+$"; ""))
        | map(select(length > 0))
      )
      else . end
    | if ($telegram_home_channel | length) > 0
      then .channels.telegram.defaultTo = $telegram_home_channel
      else . end
    else . end
  # Workboard plugin (opt-in): the standard plugin entry shape — see
  # openclaw docs/plugins/workboard.md.
  | if $workboard_enabled == "true"
    then .plugins.entries.workboard = { enabled: true, config: {} }
    else . end
  # Capability toggles: deny the tool ids backing each disabled capability.
  # Only touch .tools when something is actually disabled, so the default
  # (no toggles) renders byte-identical to before.
  | if ($deny_tools | length) > 0
    then .tools.deny = ($deny_tools | split(" ") | map(select(length > 0)))
    else . end
  ' /opt/perkos/openclaw.template.json > "$OPENCLAW_CONFIG_PATH"

chmod 600 "$OPENCLAW_CONFIG_PATH"

echo "perkos-entrypoint: wrote $OPENCLAW_CONFIG_PATH (agent=$PERKOS_AGENT_NAME id=$PERKOS_AGENT_ID)"
echo "perkos-entrypoint: channel plugins — telegram=$TELEGRAM_PLUGIN_ENABLED slack=$SLACK_PLUGIN_ENABLED discord=$DISCORD_PLUGIN_ENABLED"
if [ -n "$DENY_TOOLS" ]; then
  echo "perkos-entrypoint: capability toggles — tools.deny=[$DENY_TOOLS] (from PERKOS_DISABLED_TOOLS=${PERKOS_DISABLED_TOOLS:-})"
fi

# Bundled PerkOS skills (baked at /opt/perkos-skills/ in the Dockerfile).
# Copy them into the workspace skills dir where OpenClaw auto-discovers
# skills. perkos-platform-tools ships perkos_tools.py, which the model
# runs to drive the project job board (createTask, updateTaskStatus, …)
# via the bridge's local tools-token listener. Done before the open-source
# skills fetch below so user picks layer on top.
WORKSPACE_DIR="${OPENCLAW_WORKSPACE:-$CONFIG_DIR/workspace}"
if [ -d /opt/perkos-skills ]; then
  mkdir -p "$WORKSPACE_DIR/skills"
  for d in /opt/perkos-skills/*/; do
    [ -d "$d" ] || continue
    n=$(basename "$d")
    rm -rf "$WORKSPACE_DIR/skills/$n"
    cp -r "$d" "$WORKSPACE_DIR/skills/$n"
  done
  echo "perkos-entrypoint: bundled skills installed: $(ls "$WORKSPACE_DIR/skills" 2>/dev/null | tr '\n' ' ')"
fi

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

# ── Multi-agent (co-resident agents in one runtime) — Phase 1 spike ───────────
# The PRIMARY agent is the default (rendered above from PERKOS_AGENT_*,
# unchanged). When PERKOS_PROFILES_B64 is set this runtime ALSO hosts the
# co-resident agents it carries: the renderer patches the openclaw.json with an
# `agents.list` (primary default:true + one entry per co-resident, each with its
# own workspace) and writes each co-resident's AGENTS.md. OpenClaw routes by
# agentId natively. Absent → no-op; single-agent boot is unchanged. Co-residents
# inherit agents.defaults (model, etc.); per-agent model + state isolation are
# follow-ups. VALIDATE with a Docker build + 2-agent smoke before shipping.
if [ -n "${PERKOS_PROFILES_B64:-}" ]; then
  echo "perkos-entrypoint: rendering co-resident agents into agents.list..."
  OPENCLAW_CONFIG_PATH="$OPENCLAW_CONFIG_PATH" \
  OPENCLAW_WORKSPACE="${OPENCLAW_WORKSPACE:-$CONFIG_DIR/workspace}" \
  PERKOS_PROFILES_B64="$PERKOS_PROFILES_B64" \
  PERKOS_AGENT_ID="$PERKOS_AGENT_ID" \
  PERKOS_AGENT_NAME="$PERKOS_AGENT_NAME" \
  PERKOS_AGENT_SOUL_B64="${PERKOS_AGENT_SOUL_B64:-}" \
  python3 /usr/local/bin/perkos-render-openclaw-agents.py \
    || echo "perkos-entrypoint: co-resident render failed — continuing single-agent"
  chmod 600 "$OPENCLAW_CONFIG_PATH" 2>/dev/null || true
fi

# ── Restore a hibernation snapshot if one exists (no-op on first ever launch
# or when PERKOS_HIBERNATION_S3_URI is unset). Runs AFTER the config render +
# persona/bundled-skill writes (the snapshot's deterministic copies just win,
# identical to a fresh render) but BEFORE the open-source skill fetch below, so
# freshly-fetched skill content wins over any stale snapshot copy. ─────────────
echo "perkos-entrypoint: checking for hibernation snapshot..."
/usr/local/bin/perkos-restore.sh || \
  echo "perkos-entrypoint: restore failed (continuing with fresh state)"

# Managed channel behavior. Install AFTER snapshot restore and co-resident
# rendering so stale snapshots cannot remove it and every agent workspace gets
# the same latency/UX guardrails. The marked block is replaced atomically on
# each boot, preserving the user's persona and any instructions around it.
install_perkos_chat_policy() {
  _workspace="$1"
  _agents="$_workspace/AGENTS.md"
  _tmp="$_workspace/.AGENTS.md.perkos.$$"
  mkdir -p "$_workspace"
  if [ -f "$_agents" ]; then
    awk '
      /^<!-- PERKOS_MANAGED_CHAT_POLICY_START -->$/ { skip=1; next }
      /^<!-- PERKOS_MANAGED_CHAT_POLICY_END -->$/   { skip=0; next }
      !skip { print }
    ' "$_agents" > "$_tmp"
  else
    : > "$_tmp"
  fi
  printf '\n' >> "$_tmp"
  cat /opt/perkos/perkos-chat-policy.md >> "$_tmp"
  mv "$_tmp" "$_agents"
  chmod 644 "$_agents"
}

for _workspace in "$CONFIG_DIR"/workspace*; do
  [ -d "$_workspace" ] || continue
  install_perkos_chat_policy "$_workspace"
done
echo "perkos-entrypoint: managed chat policy installed in agent workspaces"

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

# ── Periodic state snapshot (hibernation backup) ──────────────────────────────
# Snapshot the OpenClaw home → S3 (client-side encrypted) every
# PERKOS_SNAPSHOT_INTERVAL_SEC (default 300s) so a hibernated agent can be
# cloned/restored on wake. Backgrounded before we hand off to the gateway; it
# re-parents to PID 1 (tini) and keeps running. No-op unless both
# PERKOS_HIBERNATION_S3_URI + _KMS_KEY are set. restore.sh already ran above, so
# the first snapshot reflects the restored state. See HIBERNATION-SNAPSHOT-DESIGN.md.
if [ -n "${PERKOS_HIBERNATION_S3_URI:-}" ] && [ -n "${PERKOS_HIBERNATION_KMS_KEY:-}" ]; then
  (
    while sleep "${PERKOS_SNAPSHOT_INTERVAL_SEC:-300}"; do
      /usr/local/bin/perkos-snapshot.sh >/dev/null 2>&1 || true
    done
  ) &
  echo "perkos-entrypoint: periodic state snapshot enabled (every ${PERKOS_SNAPSHOT_INTERVAL_SEC:-300}s)"
fi

exec "$@"
