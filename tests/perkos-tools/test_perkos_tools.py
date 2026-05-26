"""Unit tests for perkos_tools.py — runs against a fake bridge + tools API.

No external services touched. We spin up a tiny http.server in a thread
that impersonates both endpoints, then drive the CLI's main() with
patched env vars and capture stdout/stderr.

Run from the repo root:
    python3 -m pytest tests/perkos-tools/ -v
or just:
    python3 tests/perkos-tools/test_perkos_tools.py
"""

from __future__ import annotations

import io
import json
import os
import sys
import threading
import unittest
from contextlib import redirect_stderr, redirect_stdout
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import urlparse

SCRIPT_DIR = (
    Path(__file__).resolve().parent.parent.parent
    / "images" / "hermes" / "skills" / "perkos-platform-tools" / "scripts"
)
sys.path.insert(0, str(SCRIPT_DIR))

import perkos_tools  # noqa: E402

BRIDGE_AUTH = "test-bridge-secret"
TOKEN_BODY = {
    "token": "header.payload.signature",
    "exp": 9_999_999_999,
    "toolsApiUrl": "",  # patched per-server
}


class _FakeHandler(BaseHTTPRequestHandler):
    """Handles BOTH bridge token-mint and tools-API tool dispatch on one server."""

    # Set by the test fixture before each test.
    tools_response: dict = {"ok": True, "data": {"hits": []}}
    tools_status: int = 200
    received_token: list = []
    received_auth_header: list = []

    def log_message(self, *_a, **_kw):
        pass  # quiet

    def _read_body(self) -> dict:
        length = int(self.headers.get("content-length") or "0")
        raw = self.rfile.read(length).decode("utf-8") if length else ""
        return json.loads(raw) if raw else {}

    def _send_json(self, status: int, body: dict) -> None:
        payload = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/v1/tools-token":
            self.received_auth_header.append(self.headers.get("x-bridge-auth"))
            body = self._read_body()
            if self.headers.get("x-bridge-auth") != BRIDGE_AUTH:
                self._send_json(401, {"error": "bridge auth"})
                return
            if not body.get("convId"):
                self._send_json(400, {"error": "missing convId"})
                return
            response = dict(TOKEN_BODY)
            response["toolsApiUrl"] = f"http://127.0.0.1:{self.server.server_address[1]}"
            self._send_json(200, response)
            return

        if path.startswith("/v1/tools/"):
            auth = self.headers.get("authorization", "")
            self.received_token.append(auth)
            self._send_json(self.tools_status, self.tools_response)
            return

        self._send_json(404, {"error": "not found"})

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/v1/tools":
            auth = self.headers.get("authorization", "")
            self.received_token.append(auth)
            self._send_json(200, {"tools": [{"name": "listMyAgents"}]})
            return
        self._send_json(404, {"error": "not found"})


def _start_server() -> tuple[HTTPServer, threading.Thread, str]:
    server = HTTPServer(("127.0.0.1", 0), _FakeHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    port = server.server_address[1]
    return server, thread, f"http://127.0.0.1:{port}"


class PerkosToolsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server, cls.thread, cls.url = _start_server()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.thread.join(timeout=2)

    def setUp(self):
        # Reset shared state on the handler class between tests.
        _FakeHandler.tools_response = {"ok": True, "data": {"agents": []}}
        _FakeHandler.tools_status = 200
        _FakeHandler.received_token = []
        _FakeHandler.received_auth_header = []
        os.environ["PERKOS_BRIDGE_URL"] = self.url
        os.environ["A2A_BRIDGE_AUTH_SECRET"] = BRIDGE_AUTH
        os.environ.pop("PERKOS_CONV_ID", None)

    def _run(self, argv):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            try:
                code = perkos_tools.main(argv)
            except SystemExit as e:
                code = e.code if isinstance(e.code, int) else 1
        return code, out.getvalue(), err.getvalue()

    def test_call_listMyAgents_returns_0(self):
        code, out, err = self._run(["call", "listMyAgents", "{}", "--conv-id", "c1"])
        self.assertEqual(code, 0, msg=f"err={err}")
        self.assertIn('"ok": true', out)
        # Bridge auth was actually sent
        self.assertEqual(_FakeHandler.received_auth_header[0], BRIDGE_AUTH)
        # JWT Bearer made it through to the tools-API call
        self.assertEqual(_FakeHandler.received_token[0], "Bearer header.payload.signature")

    def test_falsy_ok_returns_2(self):
        _FakeHandler.tools_response = {"ok": False, "errorClass": "NOT_FOUND", "message": "x"}
        _FakeHandler.tools_status = 404
        code, out, _ = self._run(["call", "getMyAgent", '{"name":"x"}', "--conv-id", "c1"])
        self.assertEqual(code, 2)
        self.assertIn("NOT_FOUND", out)

    def test_5xx_returns_3(self):
        _FakeHandler.tools_response = {"ok": False, "errorClass": "INTERNAL", "message": "boom"}
        _FakeHandler.tools_status = 500
        code, _, _ = self._run(["call", "listMyAgents", "{}", "--conv-id", "c1"])
        self.assertEqual(code, 3)

    def test_list_tools(self):
        code, out, _ = self._run(["list-tools", "--conv-id", "c1"])
        self.assertEqual(code, 0)
        self.assertIn("listMyAgents", out)

    def test_missing_bridge_auth_exits_4(self):
        del os.environ["A2A_BRIDGE_AUTH_SECRET"]
        code, _, err = self._run(["call", "listMyAgents", "{}", "--conv-id", "c1"])
        self.assertEqual(code, 4)
        self.assertIn("A2A_BRIDGE_AUTH_SECRET", err)

    def test_missing_conv_id_exits_4(self):
        code, _, err = self._run(["call", "listMyAgents", "{}"])
        self.assertEqual(code, 4)
        self.assertIn("conv-id", err)

    def test_conv_id_from_env(self):
        os.environ["PERKOS_CONV_ID"] = "from-env"
        code, _, err = self._run(["call", "listMyAgents", "{}"])
        self.assertEqual(code, 0, msg=f"err={err}")

    def test_bad_args_json_exits_4(self):
        code, _, err = self._run(["call", "listMyAgents", "not-json", "--conv-id", "c1"])
        self.assertEqual(code, 4)
        self.assertIn("valid JSON", err)

    def test_args_json_must_be_object(self):
        code, _, err = self._run(["call", "listMyAgents", "[]", "--conv-id", "c1"])
        self.assertEqual(code, 4)
        self.assertIn("JSON object", err)

    def test_bridge_unreachable_exits_3(self):
        os.environ["PERKOS_BRIDGE_URL"] = "http://127.0.0.1:1"  # nothing listens here
        code, _, err = self._run(["call", "listMyAgents", "{}", "--conv-id", "c1"])
        self.assertEqual(code, 3)
        self.assertIn("bridge unreachable", err.lower())


if __name__ == "__main__":
    unittest.main(verbosity=2)
