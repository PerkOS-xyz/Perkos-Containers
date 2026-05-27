"""Farcaster platform adapter for Hermes.

Bridges the Farcaster protocol (via Neynar's hosted API + webhooks) to
Hermes's ``BasePlatformAdapter`` contract so an agent can:

* Receive casts that mention it (or appear in a configured channel).
* Reply with casts authored by its own signer.

Why Neynar (vs. running a hub directly):
    Hubs require maintaining a libp2p node and following Farcaster's
    sync protocol — operationally heavy for a per-agent container.
    Neynar is the de-facto SaaS Farcaster API and supports both write
    (cast publishing) and webhook delivery for reads. Trading some
    decentralization purity for a 95% reduction in operational
    complexity is the right call at MVP.

Design notes:
    * The HTTP layer is injected via the ``http`` parameter so unit
      tests don't need network access. In production, ``plugin.register``
      passes a real :class:`httpx.AsyncClient`.
    * No state is held in-memory beyond the active connection — all
      per-conversation state lives in Hermes's session store, keyed by
      the Farcaster cast hash + parent thread root.
    * The adapter never accepts wallet/identity input from the LLM.
      The signer identity is fixed at agent provisioning time
      (FARCASTER_SIGNER_UUID env). The LLM cannot cast as anyone else.
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass
from typing import Any, Awaitable, Callable, Dict, Optional, Protocol

logger = logging.getLogger(__name__)

NEYNAR_BASE_URL = "https://api.neynar.com"
CAST_MAX_CHARS = 320  # Farcaster protocol limit on cast text length.


class HttpClient(Protocol):
    """The minimal HTTP surface the adapter uses.

    Modeled on httpx.AsyncClient so a real client is a drop-in. Tests
    pass a fake whose ``post`` returns canned responses.
    """

    async def post(
        self,
        url: str,
        *,
        headers: Optional[Dict[str, str]] = None,
        json: Optional[Dict[str, Any]] = None,
    ) -> "HttpResponse": ...


class HttpResponse(Protocol):
    status_code: int

    def json(self) -> Dict[str, Any]: ...
    @property
    def text(self) -> str: ...


@dataclass
class FarcasterConfig:
    """Configuration extracted from env vars at startup.

    Kept as a dataclass (not pydantic) to avoid pulling pydantic into
    the plugin runtime. Hermes already validates env presence via the
    ``required_env`` block in plugin.yaml; this is the typed snapshot
    after that gate.
    """

    neynar_api_key: str
    signer_uuid: str
    fid: int
    webhook_secret: Optional[str] = None
    reply_visibility: str = "mentions"  # "mentions" | "all"
    parent_channel: Optional[str] = None


@dataclass
class InboundCast:
    """A cast that came in via the webhook and is destined for the agent.

    The adapter normalizes Neynar's webhook payload into this shape
    before handing it to Hermes's session router.
    """

    hash: str
    thread_hash: str
    author_fid: int
    author_username: str
    text: str
    parent_url: Optional[str] = None
    # Original Neynar payload, kept for debugging only — never
    # forwarded to the LLM.
    raw: Dict[str, Any] = None  # type: ignore[assignment]


@dataclass
class SendResult:
    """The contract Hermes's gateway expects back from ``send()``."""

    success: bool
    message_id: Optional[str] = None
    error: Optional[str] = None


# Callback type the adapter invokes when an inbound cast arrives. In
# production this is the bound method
# ``BasePlatformAdapter.handle_message`` provided by Hermes upstream;
# in tests it's a vi.fn-style mock that records calls.
InboundHandler = Callable[[InboundCast], Awaitable[None]]


class FarcasterAdapter:
    """Hermes platform adapter for Farcaster via Neynar.

    Lifecycle:
        * :meth:`connect` — validate auth with Neynar, register the
          webhook subscription so inbound casts arrive at our HTTP
          endpoint. Sets ``self._connected = True``.
        * :meth:`handle_webhook` — called by Hermes's gateway HTTP
          server whenever ``/webhooks/farcaster`` receives a POST.
          Verifies the HMAC, normalizes, dispatches via
          :attr:`_inbound_handler`.
        * :meth:`send` — outbound; publishes a cast via the Neynar
          ``cast/`` endpoint signed by ``signer_uuid``.
        * :meth:`disconnect` — best-effort webhook unregister.
    """

    def __init__(
        self,
        config: FarcasterConfig,
        http: HttpClient,
        inbound_handler: InboundHandler,
    ) -> None:
        self._config = config
        self._http = http
        self._inbound_handler = inbound_handler
        self._connected = False

    @property
    def connected(self) -> bool:
        return self._connected

    async def connect(self) -> bool:
        """Verify auth and mark the adapter ready.

        We don't strictly need to register the webhook here — the
        webhook subscription is created out-of-band when the agent is
        provisioned (the PerkOS provisioning flow gives Neynar the
        agent's webhook URL once). What we DO need at startup is to
        confirm the signer is alive and the API key works, because a
        misconfigured agent should fail fast at boot rather than
        silently accept casts it can't reply to.
        """

        try:
            response = await self._http.post(
                f"{NEYNAR_BASE_URL}/v2/farcaster/signer",
                headers=self._headers(),
                json={"signer_uuid": self._config.signer_uuid},
            )
        except Exception as exc:  # pragma: no cover - covered by tests via raise side-effects
            logger.exception("farcaster: connect failed talking to Neynar: %s", exc)
            return False

        if response.status_code != 200:
            logger.error(
                "farcaster: signer check failed status=%s body=%s",
                response.status_code,
                response.text,
            )
            return False

        self._connected = True
        logger.info("farcaster: adapter ready (fid=%s)", self._config.fid)
        return True

    async def disconnect(self) -> None:
        """No-op for now: webhook subscriptions outlive container restarts.

        Future: deregister the webhook on graceful shutdown so a torn-down
        agent stops being notified. Not done at MVP because the webhook
        registration is owned by the provisioner, not the runtime.
        """

        self._connected = False

    async def handle_webhook(
        self,
        payload: Dict[str, Any],
        signature: Optional[str] = None,
    ) -> bool:
        """Process one Neynar webhook delivery.

        Returns ``True`` if the inbound was accepted and dispatched,
        ``False`` if it was rejected (bad signature, wrong event type,
        not addressed to this agent). The HTTP layer can map False to
        a 202 (accepted-but-ignored) so Neynar doesn't retry.
        """

        if self._config.webhook_secret and not self._verify_signature(payload, signature):
            logger.warning("farcaster: rejected webhook with bad signature")
            return False

        if not self._is_addressed_to_us(payload):
            return False

        try:
            cast = self._normalize(payload)
        except KeyError as exc:
            # Defensive — Neynar's payload shape is documented but the
            # adapter shouldn't crash on a malformed delivery.
            logger.warning("farcaster: dropped malformed webhook (missing %s)", exc)
            return False

        # Dispatch in the background so the webhook HTTP request
        # returns quickly. The downstream handler can take seconds when
        # the agent has to load context.
        asyncio.create_task(self._dispatch(cast))
        return True

    async def send(
        self,
        text: str,
        *,
        parent_hash: Optional[str] = None,
    ) -> SendResult:
        """Publish a cast as the agent's signer.

        ``parent_hash`` is the cast we're replying to. When unset, the
        cast is a root cast (no thread parent). The MVP wires this to
        an autoreply, so callers will always supply it.
        """

        # Farcaster protocol limit. We don't try to chunk-split — the
        # agent is told via SOUL/runbook to keep replies under 320
        # characters. If it goes over we hard-truncate with an
        # ellipsis so the cast publish doesn't fail.
        if len(text) > CAST_MAX_CHARS:
            text = text[: CAST_MAX_CHARS - 1] + "…"

        body: Dict[str, Any] = {
            "signer_uuid": self._config.signer_uuid,
            "text": text,
        }
        if parent_hash:
            body["parent"] = parent_hash
        if self._config.parent_channel and not parent_hash:
            # New top-level casts go to the configured channel; replies
            # inherit the parent's channel automatically.
            body["channel_id"] = self._config.parent_channel

        try:
            response = await self._http.post(
                f"{NEYNAR_BASE_URL}/v2/farcaster/cast",
                headers=self._headers(),
                json=body,
            )
        except Exception as exc:  # pragma: no cover
            logger.exception("farcaster: send failed: %s", exc)
            return SendResult(success=False, error=str(exc))

        if response.status_code >= 400:
            return SendResult(
                success=False,
                error=f"HTTP {response.status_code}: {response.text[:200]}",
            )

        data = response.json()
        cast_hash = (data.get("cast") or {}).get("hash")
        return SendResult(success=True, message_id=cast_hash)

    # ------------------------------------------------------------------
    # Internals
    # ------------------------------------------------------------------

    def _headers(self) -> Dict[str, str]:
        return {
            "x-api-key": self._config.neynar_api_key,
            "content-type": "application/json",
        }

    def _verify_signature(
        self,
        payload: Dict[str, Any],
        signature: Optional[str],
    ) -> bool:
        """HMAC-SHA512 verification per Neynar's docs.

        Imported lazily so the adapter has no hard crypto dependency
        when webhooks are run without HMAC (e.g. in dev/test). The
        crypto path executes only when ``webhook_secret`` is set in
        config.
        """

        import hashlib
        import hmac
        import json

        if not signature:
            return False

        secret = self._config.webhook_secret or ""
        serialized = json.dumps(payload, separators=(",", ":"), sort_keys=True)
        expected = hmac.new(
            secret.encode("utf-8"),
            serialized.encode("utf-8"),
            hashlib.sha512,
        ).hexdigest()
        return hmac.compare_digest(expected, signature)

    def _is_addressed_to_us(self, payload: Dict[str, Any]) -> bool:
        """True iff the cast should trigger an agent response.

        Three trigger modes, controlled by reply_visibility:
          - "mentions" (default): the agent's FID is in the cast's
            mentioned_profiles.
          - "all": every inbound cast triggers a response (only
            sensible when parent_channel is also set to scope it).
        """

        if payload.get("type") != "cast.created":
            return False

        cast = payload.get("data") or {}
        if self._config.reply_visibility == "mentions":
            mentioned = cast.get("mentioned_profiles") or []
            return any(p.get("fid") == self._config.fid for p in mentioned)

        # "all" mode — still gated by channel scoping if configured,
        # otherwise the agent would respond to every cast on the
        # network, which is plainly broken.
        if self._config.parent_channel:
            return cast.get("parent_url") == self._config.parent_channel

        return False

    def _normalize(self, payload: Dict[str, Any]) -> InboundCast:
        cast = payload["data"]
        author = cast["author"]
        return InboundCast(
            hash=cast["hash"],
            thread_hash=cast.get("thread_hash") or cast["hash"],
            author_fid=author["fid"],
            author_username=author.get("username", ""),
            text=cast.get("text", ""),
            parent_url=cast.get("parent_url"),
            raw=payload,
        )

    async def _dispatch(self, cast: InboundCast) -> None:
        try:
            await self._inbound_handler(cast)
        except Exception:  # pragma: no cover
            # Inbound handler crashes must not poison the webhook loop.
            logger.exception("farcaster: inbound handler raised for cast=%s", cast.hash)
