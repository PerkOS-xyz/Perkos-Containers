#!/usr/bin/env python3
"""Render co-resident Hermes profiles from PERKOS_PROFILES_B64.

Phase 1 multi-agent spike (PHASE-1-MULTI-AGENT-DESIGN.md). One runtime hosts N
agents: the PRIMARY agent is the default profile at HERMES_HOME (rendered by the
entrypoint from PERKOS_AGENT_*, unchanged). Each entry in PERKOS_PROFILES_B64
becomes a NAMED profile under HERMES_HOME/profiles/<id>/ with its own:

  - config.yaml : envsubst of the template with that profile's LLM key/model/name
  - SOUL.md     : the profile's persona (from soulB64)
  - .env        : the profile's isolated secret(s) so Hermes' fail-closed
                  get_secret() resolves the right key per profile in multiplex mode

Backward-compatible: with no PERKOS_PROFILES_B64 the entrypoint never invokes us,
so the single-agent boot is byte-identical to before. Co-resident skills/toolsets
are a follow-up. The entrypoint flips gateway.multiplex_profiles on after we run.
"""
import base64
import json
import os
import re
import subprocess
import sys

# Hermes profile-id grammar (frameworks/hermes-agent/hermes_cli/profiles.py).
ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
# Cap co-residents per runtime — a guard against a runaway provision payload.
MAX_PROFILES = 32


def _ok(msg):
    """Log and exit 0: a bad payload must never abort the container boot."""
    print(f"perkos-render-profiles: {msg}")
    sys.exit(0)


def main():
    home = os.environ.get("HERMES_HOME", "/opt/data")
    template = os.environ.get("PERKOS_TEMPLATE", "/opt/perkos/hermes.template.yaml")
    b64 = os.environ.get("PERKOS_PROFILES_B64", "")
    if not b64:
        _ok("no PERKOS_PROFILES_B64 — nothing to do")

    try:
        profiles = json.loads(base64.b64decode(b64))
    except Exception as e:  # noqa: BLE001 - never abort boot on bad input
        _ok(f"bad PERKOS_PROFILES_B64 ({e})")

    if not isinstance(profiles, list) or not profiles:
        _ok("no co-resident profiles")

    try:
        with open(template, "r", encoding="utf-8") as f:
            template_text = f.read()
    except OSError as e:
        _ok(f"template unreadable ({e})")

    profiles_root = os.path.join(home, "profiles")
    os.makedirs(profiles_root, exist_ok=True)
    real_root = os.path.realpath(profiles_root)

    made = 0
    for ent in profiles[:MAX_PROFILES]:
        if not isinstance(ent, dict):
            continue
        pid = str(ent.get("id", "")).strip().lower()
        if not ID_RE.match(pid):
            print(f"perkos-render-profiles: bad profile id {pid!r} — skipped")
            continue
        pdir = os.path.join(profiles_root, pid)
        # Path-escape guard: the resolved dir must stay directly under the root.
        if os.path.realpath(pdir) != os.path.join(real_root, pid):
            print(f"perkos-render-profiles: id {pid!r} escapes profiles root — skipped")
            continue
        os.makedirs(pdir, exist_ok=True)

        # Per-profile config: envsubst the shared template with this profile's
        # values. Co-residents do NOT own the api_server (the default profile's
        # gateway does), so force it off to avoid a port-bind fight on 8642.
        env = dict(os.environ)
        env["PERKOS_AGENT_ID"] = pid
        env["PERKOS_AGENT_NAME"] = str(ent.get("name", pid))
        if ent.get("llmApiKey"):
            env["PERKOS_LLM_API_KEY"] = str(ent["llmApiKey"])
        if ent.get("llmModel"):
            env["PERKOS_LLM_DEFAULT_MODEL"] = str(ent["llmModel"])
        if ent.get("llmBaseUrl"):
            env["PERKOS_LLM_BASE_URL"] = str(ent["llmBaseUrl"])
        env["API_SERVER_ENABLED"] = "false"
        try:
            rendered = subprocess.run(
                ["envsubst"],
                input=template_text,
                capture_output=True,
                text=True,
                env=env,
                check=True,
            ).stdout
        except Exception as e:  # noqa: BLE001
            print(f"perkos-render-profiles: envsubst failed for {pid} ({e}) — skipped")
            continue
        with open(os.path.join(pdir, "config.yaml"), "w", encoding="utf-8") as f:
            f.write(rendered)

        # Persona.
        soul_b64 = ent.get("soulB64")
        if soul_b64:
            try:
                with open(os.path.join(pdir, "SOUL.md"), "wb") as f:
                    f.write(base64.b64decode(soul_b64))
            except Exception as e:  # noqa: BLE001
                print(f"perkos-render-profiles: bad soulB64 for {pid} ({e})")

        # Isolated secret(s): Hermes' fail-closed get_secret() resolves the
        # active profile's scope from its own .env, so a co-resident can't read
        # a sibling's key.
        key = ent.get("llmApiKey")
        if key:
            env_path = os.path.join(pdir, ".env")
            with open(env_path, "w", encoding="utf-8") as f:
                f.write(f"PERKOS_LLM_API_KEY={key}\n")
            os.chmod(env_path, 0o600)

        made += 1
        print(f"perkos-render-profiles: profile {pid} ready ({env['PERKOS_AGENT_NAME']})")

    print(f"perkos-render-profiles: rendered {made} co-resident profile(s)")
    sys.exit(0)


if __name__ == "__main__":
    main()
