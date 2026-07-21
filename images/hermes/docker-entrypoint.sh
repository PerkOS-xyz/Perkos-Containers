#!/bin/bash
# PerkOS-Hermes entrypoint.
#
# Runs as root (upstream entrypoint will drop privileges later). We do
# four things here, then hand off to upstream:
#
#   1. Render /opt/data/config.yaml from PERKOS_* env vars
#   2. Install the perkos-platform-tools skill into $HERMES_HOME/skills/
#      where Hermes auto-discovers it
#   3. If PERKOS_HIBERNATION_S3_URI is set, restore the latest snapshot
#      into HERMES_HOME BEFORE upstream starts. No-op on first launch.
#   4. Run /opt/hermes/docker/entrypoint.sh as a CHILD (not exec), trap
#      SIGTERM, and on shutdown: stop upstream → wait → snapshot → exit
#
# Bash (not sh): we need `trap`, `wait $!`, and `kill -TERM "$PID"`.
#
# Required env vars (we fail-fast if missing rather than letting Hermes
# start with a half-baked config and produce confusing later errors):
#   - PERKOS_AGENT_ID
#   - PERKOS_AGENT_NAME
#   - PERKOS_LLM_API_KEY
#
# Optional env vars for hibernation:
#   - PERKOS_HIBERNATION_S3_URI  e.g. s3://perkos-agent-snapshots-prod/<wallet>/<name>/
#                                When set: restore on boot, snapshot on SIGTERM.
#                                When unset: both scripts no-op gracefully.

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

HERMES_HOME="${HERMES_HOME:-/opt/data}"
mkdir -p "$HERMES_HOME" "$HERMES_HOME/skills" "$HERMES_HOME/plugins/platforms"

# Render the config Hermes reads at startup. envsubst expands ${PERKOS_*}
# in the template; literal $ signs in the template must be escaped as $$.
# Upstream entrypoint also writes a default cli-config.yaml.example to
# $HERMES_HOME/config.yaml if absent — we always overwrite so the env
# vars are the source of truth for the PerkOS deploy.
#
# Plain envsubst does NOT support `${VAR:-default}` fallback syntax
# (that's a bash-only extension). The platforms block in the template
# expects toggles to render as the literal strings "true" / "false"
# so Hermes parses them as YAML booleans, not as the raw placeholder
# text. Pre-normalize each toggle to a sane default if unset, then
# export it so envsubst sees a real value and replaces `${VAR}`.
#
# truthy: accept the lenient inputs the catalog declares (true/1/yes),
# normalize to the strict "true"/"false" strings Hermes expects.
truthy() {
  case "${1:-}" in
    true|TRUE|True|1|yes|YES|Yes) echo true ;;
    *) echo false ;;
  esac
}

# api_server is enabled by default — it's the HTTP surface the
# perkos-a2a bridge sidecar posts to. Operator can opt out with
# API_SERVER_ENABLED=false.
API_SERVER_ENABLED=$(truthy "${API_SERVER_ENABLED:-true}")
API_SERVER_HOST="${API_SERVER_HOST:-0.0.0.0}"
API_SERVER_PORT="${API_SERVER_PORT:-8642}"

# Messaging gateways default OFF — a wallet enables them via the
# /agents/new wizard which sets *_ENABLED via ecsProvision.
TELEGRAM_ENABLED=$(truthy "${TELEGRAM_ENABLED:-}")
TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS:-}"
TELEGRAM_HOME_CHANNEL="${TELEGRAM_HOME_CHANNEL:-}"
SLACK_ENABLED=$(truthy "${SLACK_ENABLED:-}")
SLACK_CHANNEL_ID="${SLACK_CHANNEL_ID:-}"
FARCASTER_ENABLED=$(truthy "${FARCASTER_ENABLED:-}")

export API_SERVER_ENABLED API_SERVER_HOST API_SERVER_PORT
export TELEGRAM_ENABLED TELEGRAM_ALLOWED_USERS TELEGRAM_HOME_CHANNEL
export SLACK_ENABLED SLACK_CHANNEL_ID
export FARCASTER_ENABLED

envsubst < /opt/perkos/hermes.template.yaml > "$HERMES_HOME/config.yaml"
chmod 644 "$HERMES_HOME/config.yaml"

# Capability toggles. PERKOS_DISABLED_TOOLS is a comma-separated list of the
# built-in capability ids the wallet turned OFF in the wizard (web-search,
# code-execution, browser, memory). Empty/unset → we append NOTHING and the
# config keeps Hermes' upstream default (the hermes-cli bundle = every
# toolset), so existing/untoggled launches render identically to before.
#
# Hermes has no documented per-toolset deny key in config.yaml (disabling is
# otherwise an interactive `/tools disable`). The non-interactive way to drop
# a toolset is to define an explicit custom bundle = (default toolsets minus
# the disabled ones) and point `toolsets:` at it. Toolset names + the default
# hermes-cli membership per hermes-agent.nousresearch.com/docs/reference/toolsets-reference.
if [ -n "${PERKOS_DISABLED_TOOLS:-}" ]; then
  # Canonical hermes-cli default toolset membership. Kept explicit (not a
  # bundle reference) because we're rebuilding the list minus exclusions; if
  # upstream adds a default toolset, add it here too. perkos-board lives in
  # mcp_servers and perkos-knowledge in plugins.enabled — both orthogonal to
  # toolsets, so they're unaffected by this block.
  DEFAULT_TOOLSETS="file terminal web browser memory skills vision image_gen todo tts delegation code_execution cronjob session_search clarify safe"
  DROP=""
  _OLDIFS=$IFS
  IFS=','
  for _cap in $PERKOS_DISABLED_TOOLS; do
    _cap=$(printf '%s' "$_cap" | tr -d '[:space:]')
    case "$_cap" in
      web-search)     DROP="$DROP web" ;;
      code-execution) DROP="$DROP code_execution" ;;
      browser)        DROP="$DROP browser" ;;
      memory)         DROP="$DROP memory" ;;
      "")             ;;
      *) echo "perkos-entrypoint: WARNING unknown disabled-tool id '$_cap' — ignored" >&2 ;;
    esac
  done
  IFS=$_OLDIFS
  if [ -n "$DROP" ]; then
    KEEP=""
    for _ts in $DEFAULT_TOOLSETS; do
      _drop=false
      for _d in $DROP; do [ "$_ts" = "$_d" ] && { _drop=true; break; }; done
      $_drop || KEEP="$KEEP $_ts"
    done
    KEEP_YAML=$(printf '%s' "$KEEP" | sed 's/^ *//; s/ *$//; s/  */, /g')
    {
      echo ""
      echo "# PerkOS capability toggles (PERKOS_DISABLED_TOOLS): explicit toolset"
      echo "# bundle = hermes-cli default minus the capabilities the wallet turned"
      echo "# off in the wizard. Dropped:$DROP"
      echo "custom_toolsets:"
      echo "  perkos-default: [$KEEP_YAML]"
      echo "toolsets:"
      echo "  - perkos-default"
    } >> "$HERMES_HOME/config.yaml"
    echo "perkos-entrypoint: capability toggles applied — dropped toolsets:$DROP"
  fi
fi

# Stage our skill into the place Hermes scans. We baked it into
# /opt/perkos-skills/ in the Dockerfile (under root) and copy it now into
# HERMES_HOME/skills/ before upstream chowns the tree. Upstream's
# subsequent `chown -R hermes:hermes "$HERMES_HOME"` will hand it to the
# hermes user automatically.
if [ -d /opt/perkos-skills/perkos-platform-tools ]; then
  rm -rf "$HERMES_HOME/skills/perkos-platform-tools"
  cp -r /opt/perkos-skills/perkos-platform-tools "$HERMES_HOME/skills/perkos-platform-tools"
fi

# Stage the native PerkOS Knowledge plugin into the user-plugins dir Hermes
# scans ($HERMES_HOME/plugins/<name>/). Standalone tool plugin (stdlib-only);
# enabled via config.yaml plugins.enabled (rendered above).
if [ -d /opt/perkos-plugins/perkos-knowledge ]; then
  rm -rf "$HERMES_HOME/plugins/perkos-knowledge"
  cp -r /opt/perkos-plugins/perkos-knowledge "$HERMES_HOME/plugins/perkos-knowledge"
  echo "perkos-entrypoint: staged perkos-knowledge knowledge plugin"
fi

# Stage messaging gateway platform adapters. We only stage a platform
# if it has the env vars it needs — Hermes's PlatformRegistry won't
# instantiate an adapter without required_env (declared in each
# plugin.yaml), but staging the directory unconditionally would still
# eat startup time scanning a plugin we'll never use. Conditional
# copy keeps the loader noise out of the agent's log for inactive
# gateways.
if [ -d /opt/perkos-platforms/farcaster ] && [ -n "${FARCASTER_NEYNAR_API_KEY:-}" ]; then
  rm -rf "$HERMES_HOME/plugins/platforms/farcaster"
  cp -r /opt/perkos-platforms/farcaster "$HERMES_HOME/plugins/platforms/farcaster"
  echo "perkos-entrypoint: staged farcaster platform plugin"
fi

echo "perkos-entrypoint: wrote $HERMES_HOME/config.yaml (agent=$PERKOS_AGENT_NAME id=$PERKOS_AGENT_ID)"
echo "perkos-entrypoint: skills/ contains: $(ls "$HERMES_HOME/skills" 2>/dev/null | tr '\n' ' ')"
echo "perkos-entrypoint: plugins/platforms/ contains: $(ls "$HERMES_HOME/plugins/platforms" 2>/dev/null | tr '\n' ' ')"

# Persona from env (PerkOS template SOUL).
#
# The launcher renders the chosen template's soul to markdown and the
# provisioner base64's it into PERKOS_AGENT_SOUL_B64. Decode it to
# $HERMES_HOME/SOUL.md so the agent boots with its persona. Hermes
# reloads SOUL.md fresh each message. Takes precedence over the baked
# Assistant SOUL below; absent → fall through to defaults.
if [ -n "${PERKOS_AGENT_SOUL_B64:-}" ]; then
  if printf '%s' "$PERKOS_AGENT_SOUL_B64" | base64 -d > "${HERMES_HOME:-/opt/data}/SOUL.md" 2>/dev/null; then
    chown 10000:10000 "${HERMES_HOME:-/opt/data}/SOUL.md" 2>/dev/null || true
    echo "perkos-entrypoint: persona SOUL.md written from PERKOS_AGENT_SOUL_B64 ($(wc -c < "${HERMES_HOME:-/opt/data}/SOUL.md") bytes)"
  else
    echo "perkos-entrypoint: WARNING failed to decode PERKOS_AGENT_SOUL_B64 — using default persona"
  fi
fi

# Persist the PerkOS Assistant SOUL across rebuilds.
#
# If /opt/perkos-assistant/SOUL.md exists in the image, concatenate it
# with the runbook files at /opt/perkos-assistant/runbook/*.md and write
# the combined output to $HERMES_HOME/SOUL.md (default /opt/data/SOUL.md).
# Hermes loads SOUL.md fresh each message, so the new content takes
# effect on the very next chat without a runtime restart.
#
# Only kicks in for the PerkOS-Assistant agent (PERKOS_AGENT_NAME=
# "PerkOS-Assistant") AND when no env-provided persona already won above.

if [ -z "${PERKOS_AGENT_SOUL_B64:-}" ] && [ "${PERKOS_AGENT_NAME:-}" = "PerkOS-Assistant" ] && [ -f /opt/perkos-assistant/SOUL.md ]; then
  {
    cat /opt/perkos-assistant/SOUL.md
    if [ -d /opt/perkos-assistant/runbook ]; then
      for f in /opt/perkos-assistant/runbook/*.md; do
        [ -f "$f" ] || continue
        echo
        echo "## File: $(basename "$f")"
        echo
        cat "$f"
        echo
      done
    fi
  } > "${HERMES_HOME:-/opt/data}/SOUL.md"
  chown hermes:hermes "${HERMES_HOME:-/opt/data}/SOUL.md" 2>/dev/null || true
  echo "perkos-entrypoint: PerkOS-Assistant SOUL installed at ${HERMES_HOME:-/opt/data}/SOUL.md"
fi

# We created HERMES_HOME + skills dir as root above. Upstream entrypoint
# detects mismatched ownership and chowns to the `hermes` user (UID 10000)
# before dropping privileges — but its `mkdir -p $HERMES_HOME/skills/...`
# happens AFTER the drop, so any subdir under skills/ that doesn't exist
# yet gets blocked by our root-owned skills/ parent unless we chown
# pre-emptively. Doing it here keeps the timing right.
chown -R 10000:10000 "$HERMES_HOME" 2>/dev/null || \
  echo "perkos-entrypoint: chown HERMES_HOME failed (rootless container?) — upstream will retry"

# Restore a stashed snapshot if one exists. No-op on first ever launch
# or when PERKOS_HIBERNATION_S3_URI is unset. We run this as root before
# upstream's chown so the restored files end up with the right owner.
echo "perkos-entrypoint: checking for hibernation snapshot..."
/usr/local/bin/perkos-restore.sh || \
  echo "perkos-entrypoint: restore failed (continuing with fresh state)"

# Open-source skills (PerkOS skill packs the wallet selected in the wizard).
#
# The provisioner base64's a JSON list of { name, url } into
# PERKOS_AGENT_SKILLS_B64. Each url is a raw SKILL.md the server already
# resolved + allow-list filtered. We run AFTER restore so the freshly
# fetched (latest) skill content wins over any stale snapshot copy, and
# BEFORE the final chown below so the files end up owned by uid 10000.
#
# Hardening (a SKILL.md is injected into the system prompt — treat as a
# prompt-injection vector): the fetch runs in a sandboxed python helper
# that (1) re-checks each url host against a hard-coded allow-list, (2)
# sanitizes `name` to [a-z0-9-] so it can't escape the skills dir, (3)
# caps file size, (4) writes only to <skillsdir>/<name>/SKILL.md, and
# (5) never aborts the boot on a failed fetch.
if [ -n "${PERKOS_AGENT_SKILLS_B64:-}" ]; then
  echo "perkos-entrypoint: installing selected skill packs..."
  PERKOS_AGENT_SKILLS_B64="$PERKOS_AGENT_SKILLS_B64" \
  PERKOS_SKILLS_DIR="${HERMES_HOME:-/opt/data}/skills" \
  python3 - <<'PYSKILLS' || echo "perkos-entrypoint: skill install step failed (continuing)"
import base64, json, os, re, sys
from urllib.parse import urlparse
from urllib.request import build_opener, HTTPRedirectHandler, Request

# Host allow-list: only fetch SKILL.md from these hosts. Keep in sync with
# the server resolver (services/skillsCatalog.ts) and the OpenClaw entrypoint.
ALLOWED_HOSTS = {"raw.githubusercontent.com"}
MAX_BYTES = 256 * 1024
NAME_RE = re.compile(r"[^a-z0-9-]+")

# Refuse to follow redirects — a 30x from an allow-listed host could otherwise
# bounce us to an attacker host (the host check only sees the original URL).
# With redirects disabled a 3xx raises HTTPError, caught below → skipped.
class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None

_opener = build_opener(_NoRedirect)

skills_dir = os.path.realpath(os.environ["PERKOS_SKILLS_DIR"])
try:
    raw = base64.b64decode(os.environ["PERKOS_AGENT_SKILLS_B64"])
    entries = json.loads(raw)
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
        # Defense vs a snapshot-planted symlink redirecting the write: the
        # resolved dest must stay inside skills_dir, and we open with
        # O_NOFOLLOW so a symlink at SKILL.md is refused.
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
  chown -R 10000:10000 "${HERMES_HOME:-/opt/data}/skills" 2>/dev/null || true
fi

# ── Multi-agent profiles (co-resident agents in one runtime) ─────────────────
# SPIKE (Phase 1 — PHASE-1-MULTI-AGENT-DESIGN.md). The PRIMARY agent is the
# default profile at HERMES_HOME (rendered above from PERKOS_AGENT_*, unchanged).
# When PERKOS_PROFILES_B64 is set this runtime ALSO hosts the co-resident agents
# it carries: each becomes a named profile under $HERMES_HOME/profiles/<id>/
# (own config.yaml + SOUL.md + .env for secret isolation) and we flip the gateway
# into multiplex mode so it serves the default + every named profile. Absent →
# no-op; the single-agent boot above is byte-identical to before. Per-profile
# skills/toolsets are a follow-up. VALIDATE with a Docker build + 2-profile smoke
# test before shipping this image (the render logic has a local unit test).
if [ -n "${PERKOS_PROFILES_B64:-}" ]; then
  echo "perkos-entrypoint: rendering co-resident agent profiles..."
  if PERKOS_PROFILES_B64="$PERKOS_PROFILES_B64" \
     HERMES_HOME="${HERMES_HOME:-/opt/data}" \
     PERKOS_TEMPLATE="/opt/perkos/hermes.template.yaml" \
     python3 /usr/local/bin/perkos-render-profiles.py; then
    # The gateway reads multiplex_profiles from the default profile's config
    # (gateway/config.py accepts the top-level key). Append it once, idempotently.
    if ! grep -q '^multiplex_profiles:' "${HERMES_HOME:-/opt/data}/config.yaml"; then
      {
        echo ""
        echo "# PerkOS multi-agent: serve the default + every named profile"
        echo "multiplex_profiles: true"
      } >> "${HERMES_HOME:-/opt/data}/config.yaml"
    fi
    chown -R 10000:10000 "${HERMES_HOME:-/opt/data}/profiles" 2>/dev/null || true
    # Co-resident profiles must NOT inherit API_SERVER_KEY / API_SERVER_ENABLED:
    # Hermes' _apply_env_overrides force-enables the api_server platform for
    # EVERY profile when either is present in the gateway env, and the
    # multiplexer then rejects a secondary profile that binds a port → the
    # gateway exits ~18s in. The default profile now carries its api_server key
    # INLINE in config.yaml (hermes.template.yaml `key:`), so it still binds.
    # Unset them for the gateway process so ONLY the default owns the shared
    # listener (served to each profile via /p/<profile>/). Single-agent never
    # enters this block, so its env is untouched.
    unset API_SERVER_KEY API_SERVER_ENABLED || true
    echo "perkos-entrypoint: unset API_SERVER_KEY/ENABLED for multiplex (default owns the listener)"
  else
    echo "perkos-entrypoint: profile render failed — continuing single-agent"
  fi
fi

# ── Periodic state snapshot (hibernation backup) ────────────────────────────
# Snapshot HERMES_HOME → S3 (client-side encrypted) every
# PERKOS_SNAPSHOT_INTERVAL_SEC so a hibernated agent can be restored/cloned on
# wake. Backgrounded before we hand off to the runtime; it re-parents to PID 1
# (s6) and keeps running. No-op unless PERKOS_HIBERNATION_S3_URI + _KMS_KEY are
# set. restore.sh already ran above, so the first snapshot reflects the restored
# state. Clean snapshots happen while the agent is idle (the common
# auto-hibernation case); a snapshot-on-stop hook for point-in-time precision is
# a future refinement. See HIBERNATION-SNAPSHOT-DESIGN.md.
if [ -n "${PERKOS_HIBERNATION_S3_URI:-}" ] && [ -n "${PERKOS_HIBERNATION_KMS_KEY:-}" ]; then
  (
    while sleep "${PERKOS_SNAPSHOT_INTERVAL_SEC:-300}"; do
      /usr/local/bin/perkos-snapshot.sh >/dev/null 2>&1 || true
    done
  ) &
  echo "perkos-entrypoint: periodic state snapshot enabled (every ${PERKOS_SNAPSHOT_INTERVAL_SEC:-300}s)"
fi

# ── Single-gateway boot (fixes the gateway double-start / lock-flap) ─────────
# Hermes 0.16 runs `gateway run` under a DYNAMIC s6 service (`gateway-default`,
# auto-restart on crash) by default. On a crash the supervisor respawns the
# gateway while the prior instance's runtime lock ($HERMES_HOME/gateway.{pid,lock})
# may not be released yet → the respawn hits "Gateway runtime lock is already
# held by another instance. Exiting" and s6 flaps it; sometimes our s6 main
# program exits and the ECS task dies. The board never gets worked.
#
# Opt out of the in-container supervisor (upstream-supported knob) so the
# gateway runs as our FOREGROUND main program: one instance, one lock holder,
# no respawn race. If it ever crashes, the container exits and ECS restarts the
# task cleanly — the orchestration layer we actually want, instead of an
# in-container restart loop fighting a stale lock.
export HERMES_GATEWAY_NO_SUPERVISE=1

# Defensive: drop stale runtime state left by a snapshot restore or an unclean
# prior shutdown so the boot can't double-start the gateway. The decisive one is
# gateway_state.json: Hermes 0.16's cont-init reconciler (hermes_cli.container_boot)
# auto-starts a SUPERVISED gateway for any profile whose recorded state is
# "running" — and our foreground `gateway run` already IS the gateway. A restored
# "running" state therefore launches a SECOND gateway → PID-file race + "Port
# already in use" → flap, and the board never gets worked. Removing it (we run
# foreground via HERMES_GATEWAY_NO_SUPERVISE above) keeps exactly one gateway.
# gateway.pid/gateway.lock/processes.json are container-namespaced runtime files
# that are meaningless after a restore.
for _f in gateway_state.json processes.json gateway.pid gateway.lock; do
  rm -f "${HERMES_HOME:-/opt/data}/$_f" 2>/dev/null || true
done

echo "perkos-entrypoint: delegating to upstream entrypoint..."

# Upstream Hermes oscillates between two ENTRYPOINT shapes across
# releases:
#
#   1. s6-overlay: `/init` is the real ENTRYPOINT. It bootstraps the
#      s6 supervision tree and execs CMD itself. `docker/entrypoint.sh`
#      becomes a deprecated shim that crashes when invoked directly
#      because the s6 utilities (`s6-setuidgid`, etc) are only on PATH
#      from inside the supervision tree.
#
#   2. Non-s6: `docker/entrypoint.sh` is the real ENTRYPOINT and execs
#      CMD itself. There is no `/init`.
#
# Detect by probing `/init` and route accordingly. For the s6 case we
# can't keep PID 1 (s6 has to be PID 1 to supervise its services), so
# the snapshot-on-SIGTERM logic ceases to apply for that path —
# Hibernation snapshots in s6 mode need a cont-finish.d hook instead.
# Today the perkos-assistant deploy doesn't set
# PERKOS_HIBERNATION_S3_URI, so this is a no-op in prod; the legacy
# non-s6 path keeps the snapshot trap intact for ECS Fargate hibernation
# clients that still run that variant.

if [ -x /init ]; then
  # s6-overlay image (current upstream). `/init` MUST be PID 1: it
  # bootstraps the s6 supervision tree and then runs the container's
  # CMD as its "main program" (the canonical s6-overlay "exit when the
  # program exits" pattern — confirmed in the image's own main-hermes
  # run-script comments). So we exec /init and PASS the gateway command
  # as its args.
  #
  # History: an earlier image variant let us skip s6 via
  # PERKOS_BYPASS_S6=true and run docker/entrypoint.sh directly. Current
  # upstream turned that shim into a deprecated stub that dies with
  # `s6-setuidgid: not found` (exit 127) outside the s6 tree — so the
  # bypass is no longer viable and is intentionally ignored here. We
  # also must NOT drop the CMD: with no main program, /init starts s6
  # but never launches the gateway, so the api_server never binds.
  #
  # The main program MUST be the upstream main-wrapper.sh, not `gateway`
  # directly: the image's original ENTRYPOINT was
  # ["/init", "/opt/hermes/docker/main-wrapper.sh"], and that wrapper is
  # what (a) repopulates env via with-contenv, (b) activates the hermes
  # Python venv (`. /opt/hermes/.venv/bin/activate`), and (c) drops to the
  # `hermes` user via s6-setuidgid before exec'ing the CLI. Passing
  # `gateway run` straight to /init bypasses all of that → `gateway: not
  # found`. So route our gateway args THROUGH the wrapper.
  if [ "${PERKOS_BYPASS_S6:-}" = "true" ]; then
    echo "perkos-entrypoint: PERKOS_BYPASS_S6=true ignored — upstream requires s6; routing through /init"
  fi
  WRAPPER=/opt/hermes/docker/main-wrapper.sh
  # CMD args, if any, are the hermes subcommand; default to `gateway run`
  # (PerkOS runs Hermes in API-server mode).
  if [ "$#" -gt 0 ]; then
    set -- "$WRAPPER" "$@"
  else
    set -- "$WRAPPER" gateway run
  fi
  echo "perkos-entrypoint: exec /init $*"
  exec /init "$@"
fi

# Fork (not exec) the legacy upstream entrypoint so we keep PID 1 —
# that's how the SIGTERM trap survives long enough to snapshot. We
# forward the signal to upstream first, wait for it to drain, then
# snapshot, then exit. ECS Fargate's task stopTimeout gives us a
# generous budget (the miniapp sets it to 300s) so a small tar+upload
# comfortably fits.
/opt/hermes/docker/entrypoint.sh "$@" &
UPSTREAM_PID=$!

shutdown_handler() {
  echo "perkos-entrypoint: SIGTERM received, stopping upstream (pid=$UPSTREAM_PID)..."
  if kill -0 "$UPSTREAM_PID" 2>/dev/null; then
    kill -TERM "$UPSTREAM_PID" 2>/dev/null || true
    # Wait for upstream to finish its own shutdown. Once it's gone,
    # HERMES_HOME is in a consistent state for snapshotting.
    wait "$UPSTREAM_PID" 2>/dev/null || true
  fi
  echo "perkos-entrypoint: upstream stopped, taking final snapshot..."
  /usr/local/bin/perkos-snapshot.sh || \
    echo "perkos-entrypoint: snapshot failed (state will be lost on wake)"
  echo "perkos-entrypoint: clean shutdown complete"
  exit 0
}
trap shutdown_handler TERM INT

# `wait` is interruptible by signals — when our trap fires it interrupts
# this wait, runs the handler, then exits cleanly. Without the explicit
# `wait $UPSTREAM_PID`, signals would be ignored until upstream returned.
wait "$UPSTREAM_PID"
RC=$?
echo "perkos-entrypoint: upstream exited with code $RC (no SIGTERM seen)"
exit "$RC"
