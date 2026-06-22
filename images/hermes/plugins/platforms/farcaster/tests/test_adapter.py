"""Unit tests for the Farcaster Hermes adapter.

No network. The HttpClient surface is mocked via a tiny FakeHttp that
records calls and returns canned responses. The point isn't to verify
Neynar's API (their contract); it's to verify our normalization,
addressing, signature checking, and outbound shape stay correct.
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import pytest

# Test files can be invoked directly by `pytest tests/` from the
# plugin dir; ensure the src/ folder is importable.
PLUGIN_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PLUGIN_ROOT / "src"))

from perkos_farcaster.adapter import (  # noqa: E402  (import after path mutation)
    CAST_MAX_CHARS,
    FarcasterAdapter,
    FarcasterConfig,
    InboundCast,
)


@dataclass
class FakeResponse:
    status_code: int
    body: Dict[str, Any]
    raw_text: str = ""

    def json(self) -> Dict[str, Any]:
        return self.body

    @property
    def text(self) -> str:
        return self.raw_text or json.dumps(self.body)


class FakeHttp:
    """Records every call; returns a queue of responses in FIFO order."""

    def __init__(self, responses: List[FakeResponse]) -> None:
        self.responses = list(responses)
        self.calls: List[Tuple[str, Dict[str, Any]]] = []

    async def post(
        self,
        url: str,
        *,
        headers: Optional[Dict[str, str]] = None,
        json: Optional[Dict[str, Any]] = None,
    ) -> FakeResponse:
        self.calls.append(
            (url, {"headers": headers or {}, "json": json or {}})
        )
        if not self.responses:
            raise AssertionError(f"FakeHttp got call but no canned response left ({url})")
        return self.responses.pop(0)


def _config(**over: Any) -> FarcasterConfig:
    defaults = {
        "neynar_api_key": "key-test",
        "signer_uuid": "sig-test",
        "fid": 12345,
        "webhook_secret": None,
        "reply_visibility": "mentions",
        "parent_channel": None,
        "webhook_port": 0,  # disable the inbound server in unit tests
    }
    defaults.update(over)
    return FarcasterConfig(**defaults)


# ---------------------------------------------------------------------
# connect()
# ---------------------------------------------------------------------

def test_connect_succeeds_when_neynar_returns_200():
    http = FakeHttp([FakeResponse(200, {"signer": {"signer_uuid": "sig-test"}})])
    captured: List[InboundCast] = []
    adapter = FarcasterAdapter(_config(), http, lambda c: _noop(c))
    ok = asyncio.run(adapter.connect())
    assert ok is True
    assert adapter.connected is True
    assert len(http.calls) == 1
    url, kwargs = http.calls[0]
    assert "signer" in url
    assert kwargs["headers"]["x-api-key"] == "key-test"


def test_connect_fails_when_neynar_rejects():
    http = FakeHttp([FakeResponse(401, {"error": "bad-key"}, raw_text="bad-key")])
    adapter = FarcasterAdapter(_config(), http, lambda c: _noop(c))
    ok = asyncio.run(adapter.connect())
    assert ok is False
    assert adapter.connected is False


# ---------------------------------------------------------------------
# send()
# ---------------------------------------------------------------------

def test_send_publishes_cast_with_signer_and_parent():
    http = FakeHttp(
        [FakeResponse(200, {"cast": {"hash": "0xnewcasthash"}})]
    )
    adapter = FarcasterAdapter(_config(), http, lambda c: _noop(c))
    result = asyncio.run(adapter.send("hello, farcaster", parent_hash="0xparent"))
    assert result.success is True
    assert result.message_id == "0xnewcasthash"
    url, kwargs = http.calls[0]
    assert "cast" in url
    body = kwargs["json"]
    assert body["signer_uuid"] == "sig-test"
    assert body["text"] == "hello, farcaster"
    assert body["parent"] == "0xparent"


def test_send_truncates_over_320_chars_with_ellipsis():
    http = FakeHttp([FakeResponse(200, {"cast": {"hash": "0x"}})])
    adapter = FarcasterAdapter(_config(), http, lambda c: _noop(c))
    long_text = "x" * 500
    asyncio.run(adapter.send(long_text, parent_hash="0xp"))
    sent_text = http.calls[0][1]["json"]["text"]
    assert len(sent_text) == CAST_MAX_CHARS
    assert sent_text.endswith("…")


def test_send_failure_returns_error_with_status():
    http = FakeHttp(
        [FakeResponse(503, {"error": "unavailable"}, raw_text="unavailable")]
    )
    adapter = FarcasterAdapter(_config(), http, lambda c: _noop(c))
    result = asyncio.run(adapter.send("hello", parent_hash="0xp"))
    assert result.success is False
    assert "503" in (result.error or "")


def test_send_uses_channel_when_no_parent():
    http = FakeHttp([FakeResponse(200, {"cast": {"hash": "0x"}})])
    adapter = FarcasterAdapter(
        _config(parent_channel="chain://eip155:1/erc721:abc"), http, lambda c: _noop(c)
    )
    asyncio.run(adapter.send("hi"))
    body = http.calls[0][1]["json"]
    assert body["channel_id"] == "chain://eip155:1/erc721:abc"
    assert "parent" not in body


# ---------------------------------------------------------------------
# handle_webhook() — addressing + dispatch
# ---------------------------------------------------------------------

def test_handle_webhook_dispatches_when_agent_mentioned():
    captured: List[InboundCast] = []

    async def handler(cast: InboundCast) -> None:
        captured.append(cast)

    adapter = FarcasterAdapter(_config(), FakeHttp([]), handler)
    payload = _mention_payload(target_fid=12345)
    accepted = asyncio.run(adapter.handle_webhook(payload))
    # Allow the dispatched task to run.
    asyncio.run(asyncio.sleep(0))
    assert accepted is True
    assert len(captured) == 1
    assert captured[0].hash == "0xthecast"
    assert captured[0].author_fid == 99
    assert captured[0].text.startswith("hey @perkos")


def test_handle_webhook_ignores_cast_not_mentioning_us():
    captured: List[InboundCast] = []

    async def handler(cast: InboundCast) -> None:
        captured.append(cast)

    adapter = FarcasterAdapter(_config(), FakeHttp([]), handler)
    payload = _mention_payload(target_fid=99999)  # someone else
    accepted = asyncio.run(adapter.handle_webhook(payload))
    asyncio.run(asyncio.sleep(0))
    assert accepted is False
    assert captured == []


def test_handle_webhook_ignores_non_cast_events():
    adapter = FarcasterAdapter(_config(), FakeHttp([]), lambda c: _noop(c))
    payload = {"type": "follow.created", "data": {}}
    accepted = asyncio.run(adapter.handle_webhook(payload))
    assert accepted is False


def test_handle_webhook_all_mode_requires_channel_scope():
    """visibility=all without channel must still ignore — broken-by-default protection."""
    cfg = _config(reply_visibility="all", parent_channel=None)
    adapter = FarcasterAdapter(cfg, FakeHttp([]), lambda c: _noop(c))
    payload = _mention_payload(target_fid=999)
    accepted = asyncio.run(adapter.handle_webhook(payload))
    assert accepted is False


def test_handle_webhook_all_mode_with_channel_accepts():
    cfg = _config(reply_visibility="all", parent_channel="chan://x")
    captured: List[InboundCast] = []

    async def handler(cast: InboundCast) -> None:
        captured.append(cast)

    adapter = FarcasterAdapter(cfg, FakeHttp([]), handler)
    payload = _mention_payload(target_fid=999, parent_url="chan://x")
    accepted = asyncio.run(adapter.handle_webhook(payload))
    asyncio.run(asyncio.sleep(0))
    assert accepted is True
    assert len(captured) == 1


# ---------------------------------------------------------------------
# Signature verification
# ---------------------------------------------------------------------

def test_signature_verification_rejects_when_secret_set_and_missing_sig():
    adapter = FarcasterAdapter(
        _config(webhook_secret="topsecret"), FakeHttp([]), lambda c: _noop(c)
    )
    assert adapter._verify_signature(b'{"type":"cast.created"}', None) is False


def test_signature_verification_accepts_correct_hmac_over_raw_body():
    import hashlib
    import hmac

    # Neynar signs the EXACT raw bytes it POSTs.
    raw = b'{"type":"cast.created","data":{"hash":"0xabc"}}'
    sig = hmac.new(b"topsecret", raw, hashlib.sha512).hexdigest()
    adapter = FarcasterAdapter(
        _config(webhook_secret="topsecret"), FakeHttp([]), lambda c: _noop(c)
    )
    # Correct HMAC over the raw body → accepted.
    assert adapter._verify_signature(raw, sig) is True
    # The OLD bug: HMAC over a re-serialized (key-reordered) body → must NOT
    # validate against the raw-body signature.
    reserialized = b'{"data":{"hash":"0xabc"},"type":"cast.created"}'
    bug_sig = hmac.new(b"topsecret", reserialized, hashlib.sha512).hexdigest()
    assert adapter._verify_signature(raw, bug_sig) is False
    # Wrong/garbage signature → rejected.
    assert adapter._verify_signature(raw, "deadbeef") is False


def test_signature_verification_requires_secret_fail_closed():
    import hashlib
    import hmac

    # No webhook_secret configured → reject every inbound (fail-closed), even
    # with an otherwise well-formed signature.
    raw = b'{"type":"cast.created"}'
    sig = hmac.new(b"anything", raw, hashlib.sha512).hexdigest()
    adapter = FarcasterAdapter(
        _config(webhook_secret=None), FakeHttp([]), lambda c: _noop(c)
    )
    assert adapter._verify_signature(raw, sig) is False


def test_handle_webhook_drops_malformed_payload_without_crashing():
    adapter = FarcasterAdapter(_config(), FakeHttp([]), lambda c: _noop(c))
    # Missing "data" key — would raise KeyError if not handled.
    payload = {"type": "cast.created"}
    accepted = asyncio.run(adapter.handle_webhook(payload))
    assert accepted is False


# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------

async def _noop(cast: InboundCast) -> None:
    """Throwaway inbound handler for tests that don't care about dispatch."""


def _mention_payload(target_fid: int, parent_url: Optional[str] = None) -> Dict[str, Any]:
    return {
        "type": "cast.created",
        "data": {
            "hash": "0xthecast",
            "thread_hash": "0xroot",
            "parent_url": parent_url,
            "text": "hey @perkos how do hibernation snapshots work?",
            "author": {"fid": 99, "username": "alice"},
            "mentioned_profiles": [{"fid": target_fid, "username": "perkos"}],
        },
    }
