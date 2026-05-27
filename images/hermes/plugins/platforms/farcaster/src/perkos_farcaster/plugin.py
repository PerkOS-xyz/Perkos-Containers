"""Hermes plugin entry point.

This is the function named in ``plugin.yaml``'s ``entry_point``.
Hermes's PlatformRegistry calls ``register(ctx)`` at startup with a
context that exposes the registry hooks (``ctx.register_platform``,
``ctx.add_webhook_route``, etc).

We keep the function small: read env, build a config, instantiate the
adapter, wire it into the registry. The adapter itself
(:mod:`perkos_farcaster.adapter`) has zero knowledge of Hermes — it
talks to a minimal HttpClient protocol so unit tests don't need any
Hermes import path.
"""

from __future__ import annotations

import logging
import os
from typing import Any

from .adapter import FarcasterAdapter, FarcasterConfig

logger = logging.getLogger(__name__)


def _config_from_env() -> FarcasterConfig:
    """Build a :class:`FarcasterConfig` from the process env.

    Required vars are listed in plugin.yaml's ``required_env`` and
    Hermes's loader gates on them before calling us — but we re-check
    here so a hand-invoked test never crashes with an opaque KeyError.
    """

    api_key = os.environ.get("FARCASTER_NEYNAR_API_KEY", "").strip()
    signer = os.environ.get("FARCASTER_SIGNER_UUID", "").strip()
    fid_raw = os.environ.get("FARCASTER_FID", "").strip()
    if not (api_key and signer and fid_raw):
        raise RuntimeError(
            "farcaster plugin: required env vars missing — "
            "set FARCASTER_NEYNAR_API_KEY, FARCASTER_SIGNER_UUID, and FARCASTER_FID"
        )

    try:
        fid = int(fid_raw)
    except ValueError as exc:
        raise RuntimeError(f"farcaster plugin: FARCASTER_FID must be an integer, got {fid_raw!r}") from exc

    visibility = os.environ.get("FARCASTER_REPLY_VISIBILITY", "mentions").strip() or "mentions"
    if visibility not in {"mentions", "all"}:
        logger.warning(
            "farcaster: invalid FARCASTER_REPLY_VISIBILITY=%r, falling back to 'mentions'", visibility
        )
        visibility = "mentions"

    return FarcasterConfig(
        neynar_api_key=api_key,
        signer_uuid=signer,
        fid=fid,
        webhook_secret=os.environ.get("FARCASTER_WEBHOOK_SECRET") or None,
        reply_visibility=visibility,
        parent_channel=os.environ.get("FARCASTER_PARENT_CHANNEL") or None,
    )


def register(ctx: Any) -> None:
    """Hermes plugin entry point.

    The ``ctx`` is provided by Hermes — at the time of writing its
    surface is intentionally narrow:

      * ``ctx.register_platform(PlatformEntry)`` — register the adapter
        factory + lifecycle hooks so the gateway runner instantiates
        us when ``platforms.farcaster.enabled`` is true in config.
      * ``ctx.http_client()`` — borrow Hermes's shared httpx client so
        we don't open a second connection pool per process.

    If we're loaded by something that ISN'T Hermes (e.g. a smoke
    test), we no-op silently. The adapter is still importable for
    direct construction.
    """

    register_platform = getattr(ctx, "register_platform", None)
    http_client_factory = getattr(ctx, "http_client", None)
    if register_platform is None or http_client_factory is None:
        logger.warning("farcaster plugin: host does not expose register_platform/http_client — skipping")
        return

    config = _config_from_env()

    def adapter_factory(handler: Any) -> FarcasterAdapter:
        return FarcasterAdapter(
            config=config,
            http=http_client_factory(),
            inbound_handler=handler,
        )

    register_platform(
        name="farcaster",
        adapter_factory=adapter_factory,
        # Hermes uses this for the diagnostic dashboard; user-visible.
        description="Farcaster (via Neynar) — receive @mentions and reply as the agent's signer",
        version="0.1.0",
    )
