#!/usr/bin/env python3
"""perkos_tools — CLI bridge from Hermes to the PerkOS Platform Tools API.

Hermes runs this script via its shell tool when the LLM decides to call a
PerkOS platform tool (listMyAgents, getRunbookFor, searchKnowledge, etc).

The script:
    1. Asks the local perkos-a2a-bridge for a fresh short-lived JWT bound
       to the current chat conversation. The bridge derives the wallet
       from its own conv-registry — we never send a wallet ourselves.
    2. Calls POST {tools_api_url}/v1/tools/{name} with the JWT.
    3. Prints the API response as JSON to stdout. Errors go to stderr
       with a non-zero exit code so Hermes can surface them.

Why not call the Tools API directly?
    The Tools API needs HS256-signed claims (wallet, convId, role). The
    HMAC secret is only held by the bridge. The LLM has no business
    forging a wallet — letting it pass --wallet would defeat the entire
    point. So the bridge mediates: it KNOWS who the current caller is
    (from chat_deliver frames) and signs a token bound to them.

Env contract (all set by the container deploy compose, not the LLM):
    PERKOS_BRIDGE_URL          http://127.0.0.1:5070   (default; tools-token listener)
    A2A_BRIDGE_AUTH_SECRET     shared secret for X-Bridge-Auth header
    PERKOS_CONV_ID             default convId if --conv-id flag absent
                               (the entrypoint can set this from the
                               first chat frame's marker)

Usage:
    perkos_tools.py call <toolName> <argsJson> [--conv-id <id>] [--timeout 15]
    perkos_tools.py list-tools                  [--conv-id <id>]

Examples (what the LLM should emit verbatim via its shell tool):
    perkos_tools.py call listMyAgents '{}' --conv-id assistant-0xabc
    perkos_tools.py call searchKnowledge '{"query":"fargate ecs","limit":5}' --conv-id assistant-0xabc
    perkos_tools.py call getRunbookFor '{"topic":"04-lifecycle"}' --conv-id assistant-0xabc

Exit codes:
    0   tool returned ok=true
    2   tool returned ok=false (errorClass surfaced in stderr+stdout)
    3   bridge unreachable or returned non-2xx
    4   bad usage (missing env, malformed args)
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from typing import Any


def _die(code: int, message: str) -> None:
    print(message, file=sys.stderr)
    sys.exit(code)


def _post_json(url: str, body: dict, headers: dict, timeout: float) -> tuple[int, Any]:
    """POST JSON. Returns (status_code, parsed_body_or_text)."""
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        headers={"content-type": "application/json", **headers},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8") or "{}"
            try:
                return resp.getcode(), json.loads(raw)
            except json.JSONDecodeError:
                return resp.getcode(), raw
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace") if e.fp else ""
        try:
            return e.code, json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            return e.code, raw
    except urllib.error.URLError as e:
        _die(3, f"perkos_tools: bridge unreachable at {url}: {e.reason}")
    except TimeoutError:
        _die(3, f"perkos_tools: bridge timeout at {url}")


def _get_json(url: str, headers: dict, timeout: float) -> tuple[int, Any]:
    req = urllib.request.Request(url, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8") or "{}"
            try:
                return resp.getcode(), json.loads(raw)
            except json.JSONDecodeError:
                return resp.getcode(), raw
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace") if e.fp else ""
        try:
            return e.code, json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            return e.code, raw
    except urllib.error.URLError as e:
        _die(3, f"perkos_tools: tools API unreachable at {url}: {e.reason}")
    except TimeoutError:
        _die(3, f"perkos_tools: tools API timeout at {url}")


def _mint_token(bridge_url: str, bridge_auth: str, conv_id: str, timeout: float) -> dict:
    """Ask the bridge for a fresh Tools-API JWT. Returns {token, exp, toolsApiUrl}."""
    status, body = _post_json(
        f"{bridge_url.rstrip('/')}/v1/tools-token",
        {"convId": conv_id},
        {"x-bridge-auth": bridge_auth},
        timeout,
    )
    if status != 200 or not isinstance(body, dict) or "token" not in body:
        _die(
            3,
            f"perkos_tools: token mint failed (status {status}): "
            f"{body if isinstance(body, str) else json.dumps(body)}",
        )
    return body


def _resolve_env(args) -> tuple[str, str, str]:
    bridge_url = os.environ.get("PERKOS_BRIDGE_URL", "http://127.0.0.1:5070")
    bridge_auth = os.environ.get("A2A_BRIDGE_AUTH_SECRET", "").strip()
    conv_id = (args.conv_id or os.environ.get("PERKOS_CONV_ID") or "").strip()

    if not bridge_auth:
        _die(
            4,
            "perkos_tools: A2A_BRIDGE_AUTH_SECRET is required "
            "(set by the container deploy, not by the LLM).",
        )
    if not conv_id:
        _die(
            4,
            "perkos_tools: --conv-id is required (or set PERKOS_CONV_ID). "
            "Read it from the [PERKOS_CHAT:<id>] marker in the system message.",
        )
    return bridge_url, bridge_auth, conv_id


def _cmd_call(args) -> int:
    bridge_url, bridge_auth, conv_id = _resolve_env(args)

    try:
        tool_args = json.loads(args.args_json)
    except json.JSONDecodeError as e:
        _die(4, f"perkos_tools: argsJson is not valid JSON: {e}")
    if not isinstance(tool_args, dict):
        _die(4, "perkos_tools: argsJson must be a JSON object (got {type})".format(
            type=type(tool_args).__name__))

    token_payload = _mint_token(bridge_url, bridge_auth, conv_id, args.timeout)
    tools_api_url = token_payload["toolsApiUrl"].rstrip("/")
    token = token_payload["token"]

    status, body = _post_json(
        f"{tools_api_url}/v1/tools/{args.tool}",
        tool_args,
        {"authorization": f"Bearer {token}"},
        args.timeout,
    )

    output = body if isinstance(body, dict) else {"raw": body}
    print(json.dumps(output, indent=2))

    if status >= 500:
        return 3
    if isinstance(output, dict) and output.get("ok") is False:
        return 2
    if 200 <= status < 300:
        return 0
    # 4xx with no `ok` field — treat as tool error (rate-limited, bad input).
    return 2


def _cmd_list_tools(args) -> int:
    bridge_url, bridge_auth, conv_id = _resolve_env(args)
    token_payload = _mint_token(bridge_url, bridge_auth, conv_id, args.timeout)
    tools_api_url = token_payload["toolsApiUrl"].rstrip("/")
    token = token_payload["token"]
    status, body = _get_json(
        f"{tools_api_url}/v1/tools",
        {"authorization": f"Bearer {token}"},
        args.timeout,
    )
    output = body if isinstance(body, (dict, list)) else {"raw": body}
    print(json.dumps(output, indent=2))
    return 0 if 200 <= status < 300 else 3


def _add_common_args(p: argparse.ArgumentParser) -> None:
    """Shared flags — repeated on each subparser so the LLM can put them
    after the subcommand (matches the SKILL.md usage examples)."""
    p.add_argument(
        "--conv-id",
        dest="conv_id",
        default=None,
        help="Chat conversation id (or set PERKOS_CONV_ID).",
    )
    p.add_argument(
        "--timeout",
        type=float,
        default=15.0,
        help="HTTP timeout in seconds (default 15).",
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="perkos_tools",
        description="Call the PerkOS Platform Tools API as the current chat caller.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    call = sub.add_parser("call", help="Dispatch a tool.")
    call.add_argument("tool", help="Tool name, e.g. listMyAgents")
    call.add_argument(
        "args_json",
        help="JSON object of tool arguments. Use '{}' for tools with no args.",
    )
    _add_common_args(call)
    call.set_defaults(func=_cmd_call)

    lst = sub.add_parser("list-tools", help="Fetch the Tools API catalog.")
    _add_common_args(lst)
    lst.set_defaults(func=_cmd_list_tools)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
