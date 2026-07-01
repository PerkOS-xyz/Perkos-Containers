#!/usr/bin/env python3
"""Render OpenClaw `agents.list` for multi-agent (Phase 1 co-residents).

OpenClaw hosts N agents natively via `agents.list[]`, routed by agentId. The
single-agent PerkOS config only sets `agents.defaults`. When PERKOS_PROFILES_B64
is set, this patches the rendered openclaw.json with an `agents.list`:

  [ { primary, default:true }, { co-resident }, ... ]

The primary keeps the default workspace; each co-resident gets its own
workspace dir + AGENTS.md (persona). Co-residents inherit `agents.defaults`
(model, etc.) UNLESS the profile carries its own `llmApiKey` — then we give it a
dedicated provider (base provider cloned with that key) and point the agent's
`model.primary` at it, so its LLM usage meters to its OWN gateway key rather than
the host's. This is the OpenClaw half of per-renter key isolation (Phase 2);
Hermes does the same via its per-profile `.env` (perkos-render-profiles.py).
Backward-compatible: with no PERKOS_PROFILES_B64 the entrypoint never calls us,
and a co-resident with no `llmApiKey` still inherits `agents.defaults` unchanged.
"""
import base64
import copy
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


def base_model_id(base_provider, cfg):
    """The model id the base provider advertises (so a cloned provider can reuse
    it). Prefer the provider's first model; fall back to the id in
    agents.defaults.model.primary (`provider/model`); else a safe constant."""
    models = base_provider.get("models") if isinstance(base_provider, dict) else None
    if isinstance(models, list) and models and isinstance(models[0], dict) and models[0].get("id"):
        return str(models[0]["id"])
    primary = ((cfg.get("agents") or {}).get("defaults") or {}).get("model") or {}
    ref = primary.get("primary") if isinstance(primary, dict) else None
    if isinstance(ref, str) and "/" in ref:
        return ref.split("/", 1)[1]
    return "default"


def build_key_providers(base_provider_name, base_provider, profiles):
    """Pure: for each co-resident carrying `llmApiKey`, clone the base provider
    with that key so the agent's model calls use ITS key (usage attributes to the
    renter, not the host). Returns ({provider_name: provider_dict}, {cid: "<prov>/<model>"}).
    A co-resident with no key gets nothing here → it inherits agents.defaults."""
    providers = {}
    model_refs = {}
    if not isinstance(base_provider, dict):
        return providers, model_refs
    default_model = base_model_id(base_provider, {})
    seen = set()
    for p in profiles[:MAX_PROFILES]:
        if not isinstance(p, dict):
            continue
        cid = norm_id(p.get("id", ""), "")
        key = p.get("llmApiKey")
        if not ID_RE.match(cid) or cid in seen or not key:
            continue
        seen.add(cid)
        prov_name = f"perkos-{cid}"[:64]
        clone = copy.deepcopy(base_provider)
        clone["apiKey"] = str(key)
        if p.get("llmBaseUrl"):
            clone["baseUrl"] = str(p["llmBaseUrl"])
        # Attribution rides the key, but stamp this co-resident's id on the header
        # too so gateway usage rows group under it rather than the host's.
        if isinstance(clone.get("headers"), dict):
            clone["headers"]["x-agent-id"] = cid
        model_id = str(p.get("llmModel") or default_model)
        # The cloned provider must advertise the model the agent selects.
        if p.get("llmModel") and isinstance(clone.get("models"), list) and clone["models"]:
            first = clone["models"][0]
            if isinstance(first, dict):
                first["id"] = model_id
                first["name"] = model_id
        providers[prov_name] = clone
        model_refs[cid] = f"{prov_name}/{model_id}"
    return providers, model_refs


def build_agents_list(primary, profiles, base_ws, model_refs=None):
    """Pure: (agents.list entries, [(agent_id, workspace, soul_b64) to write]).

    The primary is entry 0 with default:true at base_ws; each valid co-resident
    follows at base_ws-<id>. Dupe ids are skipped. A co-resident present in
    `model_refs` gets a per-agent `model.primary` override (its own-key provider).
    """
    model_refs = model_refs or {}
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
        entry = {"id": cid, "name": str(p.get("name", cid)), "workspace": ws}
        if cid in model_refs:
            entry["model"] = {"primary": model_refs[cid]}
        entries.append(entry)
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

    try:
        with open(cfg_path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
    except Exception as e:  # noqa: BLE001
        print(f"perkos-render-openclaw: config unreadable ({e}) — skipping")
        sys.exit(0)

    # Per-co-resident own-key providers (Phase 2 isolation). The base provider is
    # the single entry the entrypoint rendered (renamed from "ollama" to the real
    # provider name). Cloning it keeps baseUrl/api/model shape; only the key (and
    # the x-agent-id header + optional baseUrl/model) change.
    providers = ((cfg.get("models") or {}).get("providers")) or {}
    key_providers, model_refs = ({}, {})
    if isinstance(providers, dict) and providers:
        base_name = next(iter(providers))
        key_providers, model_refs = build_key_providers(base_name, providers[base_name], profiles)

    entries, writes = build_agents_list(primary, profiles, base_ws, model_refs)

    cfg.setdefault("agents", {})["list"] = entries
    if key_providers:
        cfg.setdefault("models", {}).setdefault("providers", {}).update(key_providers)
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
        f"(primary + {len(entries) - 1} co-resident); {len(key_providers)} own-key provider(s)"
    )
    sys.exit(0)


if __name__ == "__main__":
    main()
