#!/usr/bin/env python3
"""Render OpenClaw `agents.list` for multi-agent (Phase 1 co-residents).

OpenClaw hosts N agents natively via `agents.list[]`, routed by agentId. The
single-agent PerkOS config only sets `agents.defaults`. When PERKOS_PROFILES_B64
is set, this patches the rendered openclaw.json with an `agents.list`:

  [ { primary, default:true }, { co-resident }, ... ]

The primary keeps the default workspace; each co-resident gets its own
workspace dir + AGENTS.md (persona). Co-residents inherit `agents.defaults`
(model, etc.) — per-agent model overrides + per-agent state isolation are
follow-ups. Backward-compatible: with no PERKOS_PROFILES_B64 the entrypoint
never calls us, so single-agent is unchanged.
"""
import base64
import json
import os
import re
import sys

ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
MAX_PROFILES = 32


def norm_id(value, fallback):
    slug = re.sub(r"[^a-z0-9_-]+", "-", str(value).lower()).strip("-")[:64]
    if ID_RE.match(slug):
        return slug
    fb = re.sub(r"[^a-z0-9_-]+", "-", str(fallback).lower()).strip("-")[:64]
    return fb if ID_RE.match(fb) else "agent"


def build_agents_list(primary, profiles, base_ws):
    """Pure: (agents.list entries, [(agent_id, workspace, soul_b64) to write]).

    The primary is entry 0 with default:true at base_ws; each valid co-resident
    follows at base_ws-<id>. Dupe ids are skipped.
    """
    entries = []
    writes = []
    pid = norm_id(primary.get("id", ""), "agent")
    entries.append({"id": pid, "name": primary.get("name", pid), "workspace": base_ws, "default": True})
    if primary.get("soul_b64"):
        writes.append((pid, base_ws, primary["soul_b64"]))
    seen = {pid}
    for p in profiles[:MAX_PROFILES]:
        if not isinstance(p, dict):
            continue
        cid = norm_id(p.get("id", ""), "")
        if not ID_RE.match(cid) or cid in seen:
            continue
        seen.add(cid)
        ws = f"{base_ws}-{cid}"
        entries.append({"id": cid, "name": str(p.get("name", cid)), "workspace": ws})
        if p.get("soulB64"):
            writes.append((cid, ws, p["soulB64"]))
    return entries, writes


def main():
    cfg_path = os.environ.get("OPENCLAW_CONFIG_PATH", "")
    if not cfg_path or not os.path.isfile(cfg_path):
        print(f"perkos-render-openclaw: config {cfg_path!r} missing — skipping")
        sys.exit(0)
    b64 = os.environ.get("PERKOS_PROFILES_B64", "")
    if not b64:
        print("perkos-render-openclaw: no PERKOS_PROFILES_B64 — nothing to do")
        sys.exit(0)
    try:
        profiles = json.loads(base64.b64decode(b64))
    except Exception as e:  # noqa: BLE001 — never abort boot on bad input
        print(f"perkos-render-openclaw: bad PERKOS_PROFILES_B64 ({e}) — skipping")
        sys.exit(0)
    if not isinstance(profiles, list) or not profiles:
        print("perkos-render-openclaw: no co-resident profiles — skipping")
        sys.exit(0)

    base_ws = os.environ.get("OPENCLAW_WORKSPACE") or os.path.join(
        os.path.dirname(cfg_path), "workspace"
    )
    primary = {
        "id": os.environ.get("PERKOS_AGENT_ID", "agent"),
        "name": os.environ.get("PERKOS_AGENT_NAME", "agent"),
        "soul_b64": os.environ.get("PERKOS_AGENT_SOUL_B64", ""),
    }
    entries, writes = build_agents_list(primary, profiles, base_ws)

    try:
        with open(cfg_path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
    except Exception as e:  # noqa: BLE001
        print(f"perkos-render-openclaw: config unreadable ({e}) — skipping")
        sys.exit(0)
    cfg.setdefault("agents", {})["list"] = entries
    with open(cfg_path, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)

    for aid, ws, soul_b64 in writes:
        try:
            os.makedirs(ws, exist_ok=True)
            with open(os.path.join(ws, "AGENTS.md"), "wb") as f:
                f.write(base64.b64decode(soul_b64))
        except Exception as e:  # noqa: BLE001
            print(f"perkos-render-openclaw: AGENTS.md write failed for {aid} ({e})")

    print(
        f"perkos-render-openclaw: agents.list = {len(entries)} agents "
        f"(primary + {len(entries) - 1} co-resident)"
    )
    sys.exit(0)


if __name__ == "__main__":
    main()
