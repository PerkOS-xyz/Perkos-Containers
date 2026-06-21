import json
import os
import urllib.error
import urllib.parse
import urllib.request

BASE_URL = os.environ.get("KNOWLEDGE_BASE_URL", "https://knowledge.perkos.xyz").rstrip("/")


def _headers(org_id=None, auth=False):
    headers = {"content-type": "application/json"}
    if org_id or os.environ.get("KNOWLEDGE_ORG_ID"):
        headers["x-organization-id"] = org_id or os.environ["KNOWLEDGE_ORG_ID"]
    if os.environ.get("KNOWLEDGE_AGENT_WALLET"):
        headers["x-agent-wallet"] = os.environ["KNOWLEDGE_AGENT_WALLET"]
    if os.environ.get("KNOWLEDGE_AGENT_ERC8004"):
        headers["x-agent-erc8004"] = os.environ["KNOWLEDGE_AGENT_ERC8004"]
    if os.environ.get("KNOWLEDGE_SEND_AGENT_ID") == "1" and os.environ.get("KNOWLEDGE_AGENT_ID"):
        headers["x-agent-id"] = os.environ["KNOWLEDGE_AGENT_ID"]
    if auth and os.environ.get("KNOWLEDGE_INGEST_TOKEN"):
        headers["authorization"] = "Bearer " + os.environ["KNOWLEDGE_INGEST_TOKEN"]
    return headers


def _request(method, path, body=None, org_id=None, auth=False):
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(BASE_URL + path, data=data, headers=_headers(org_id, auth), method=method)
    try:
        with urllib.request.urlopen(req, timeout=int(os.environ.get("PERKOS_TECH_TIMEOUT", "30"))) as res:
            raw = res.read().decode("utf-8")
            return json.dumps(json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace")
        try:
            payload = json.loads(raw) if raw else None
        except Exception:
            payload = {"raw": raw}
        return json.dumps({"ok": False, "status": e.code, "response": payload})
    except Exception as e:
        return json.dumps({"ok": False, "error": str(e)})


def perkos_skill_manifest(args, **kwargs):
    return _request("GET", "/skill/manifest")


def perkos_x402_policy(args, **kwargs):
    return _request("GET", "/api/x402/policy")


def perkos_knowledge_query(args, **kwargs):
    args = args or {}
    query = args.get("query", "").strip()
    if not query:
        return json.dumps({"ok": False, "error": "query_required"})
    body = {
        "query": query,
        "limit": args.get("limit", 5),
        "createRequestOnMiss": args.get("createRequestOnMiss"),
        "desired_output": args.get("desiredOutput"),
        "missing_topics": args.get("missingTopics"),
        "qualityMode": args.get("qualityMode"),
        "minConfidence": args.get("minConfidence"),
        "requireValidated": args.get("requireValidated"),
    }
    return _request("POST", "/skill/query", body, org_id=args.get("organizationId"))


def perkos_knowledge_requests_list(args, **kwargs):
    args = args or {}
    status = urllib.parse.quote(str(args.get("status", "open")))
    limit = urllib.parse.quote(str(args.get("limit", 25)))
    return _request("GET", f"/knowledge/requests?status={status}&limit={limit}")


def perkos_knowledge_request_create(args, **kwargs):
    args = args or {}
    query = args.get("query", "").strip()
    if not query:
        return json.dumps({"ok": False, "error": "query_required"})
    return _request("POST", "/knowledge/requests", {
        "query": query,
        "priority": args.get("priority"),
        "desired_output": args.get("desiredOutput"),
        "missing_topics": args.get("missingTopics"),
        "notes": args.get("notes"),
        "allow_duplicate": args.get("allowDuplicate"),
    })


def perkos_knowledge_request_claim(args, **kwargs):
    args = args or {}
    request_id = args.get("requestId", "").strip()
    if not request_id:
        return json.dumps({"ok": False, "error": "request_id_required"})
    return _request("POST", f"/knowledge/requests/{urllib.parse.quote(request_id)}/claim", {
        "notes": args.get("notes"),
    }, auth=True)


def perkos_knowledge_request_fulfill(args, **kwargs):
    args = args or {}
    request_id = args.get("requestId", "").strip()
    if not request_id:
        return json.dumps({"ok": False, "error": "request_id_required"})
    return _request("POST", f"/knowledge/requests/{urllib.parse.quote(request_id)}/fulfill", {
        "research_item_ids": args.get("researchItemIds", []),
        "notes": args.get("notes"),
    }, auth=True)


def perkos_knowledge_request_validate(args, **kwargs):
    args = args or {}
    request_id = args.get("requestId", "").strip()
    if not request_id:
        return json.dumps({"ok": False, "error": "request_id_required"})
    return _request("POST", f"/knowledge/requests/{urllib.parse.quote(request_id)}/validate", {
        "accepted": args.get("accepted", True),
        "validation_notes": args.get("validationNotes") or args.get("notes"),
    }, auth=True)


def perkos_knowledge_submit_research(args, **kwargs):
    args = args or {}
    items = args.get("items") or []
    if not isinstance(items, list) or not items:
        return json.dumps({"ok": False, "error": "items_required"})
    body = {
        "source": args.get("source"),
        "visibility": args.get("visibility"),
        "organization_id": args.get("organizationId"),
        "contribution_type": args.get("contributionType"),
        "items": items,
    }
    return _request("POST", "/api/ingest/research", body, org_id=args.get("organizationId"), auth=True)
