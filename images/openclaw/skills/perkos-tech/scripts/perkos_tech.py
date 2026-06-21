#!/usr/bin/env python3
import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

BASE_URL = os.environ.get("KNOWLEDGE_BASE_URL", "https://knowledge.perkos.xyz").rstrip("/")
LLM_URL = os.environ.get("PERKOS_LLM_URL", "https://api.llm.perkos.xyz").rstrip("/")


def openclaw_agent_id():
    if os.environ.get("KNOWLEDGE_SEND_AGENT_ID") != "1":
        return None
    for path in ("/root/.openclaw/openclaw.json", os.path.expanduser("~/.openclaw/openclaw.json")):
        try:
            with open(path, "r", encoding="utf-8") as f:
                cfg = json.load(f)
            return (((cfg.get("models") or {}).get("providers") or {}).get("ollama") or {}).get("headers", {}).get("x-agent-id") or os.environ.get("KNOWLEDGE_AGENT_ID")
        except Exception:
            continue
    return os.environ.get("KNOWLEDGE_AGENT_ID")


def headers(auth=False):
    h = {"content-type": "application/json"}
    agent_id = openclaw_agent_id()
    if agent_id:
        h["x-agent-id"] = agent_id
    if os.environ.get("KNOWLEDGE_AGENT_WALLET"):
        h["x-agent-wallet"] = os.environ["KNOWLEDGE_AGENT_WALLET"]
    if os.environ.get("KNOWLEDGE_AGENT_ERC8004"):
        h["x-agent-erc8004"] = os.environ["KNOWLEDGE_AGENT_ERC8004"]
    if os.environ.get("KNOWLEDGE_ORG_ID"):
        h["x-organization-id"] = os.environ["KNOWLEDGE_ORG_ID"]
    if auth and os.environ.get("KNOWLEDGE_INGEST_TOKEN"):
        h["authorization"] = "Bearer " + os.environ["KNOWLEDGE_INGEST_TOKEN"]
    return h


def clean_body(body):
    if body is None:
        return None
    return {key: value for key, value in body.items() if value is not None}


def request(method, path, body=None, auth=False):
    body = clean_body(body)
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(BASE_URL + path, data=data, headers=headers(auth), method=method)
    try:
        with urllib.request.urlopen(req, timeout=int(os.environ.get("PERKOS_TECH_TIMEOUT", "30"))) as res:
            raw = res.read().decode("utf-8")
            return res.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace")
        try:
            payload = json.loads(raw) if raw else None
        except Exception:
            payload = {"raw": raw}
        return e.code, payload



def llm_request(path, token):
    req = urllib.request.Request(LLM_URL + path, headers={"authorization": "Bearer " + token}, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=int(os.environ.get("PERKOS_TECH_TIMEOUT", "30"))) as res:
            raw = res.read().decode("utf-8")
            return res.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace")
        try:
            payload = json.loads(raw) if raw else None
        except Exception:
            payload = {"raw": raw}
        return e.code, payload


def current_agent_id():
    return os.environ.get("KNOWLEDGE_AGENT_ID") or os.environ.get("PERKOS_AGENT_ID") or openclaw_agent_id() or ""


def filter_usage_for_agent(payload, agent_id):
    if not agent_id or not isinstance(payload, dict) or not isinstance(payload.get("agents"), list):
        return payload
    out = dict(payload)
    out["agents"] = [a for a in payload["agents"] if a.get("agentGuid") == agent_id or a.get("agentLabel") == agent_id]
    out["filter"] = {"agentId": agent_id}
    return out

def parse_evidence(args):
    evidence = []
    if args.evidence:
        try:
            parsed = json.loads(args.evidence)
        except Exception as exc:
            raise SystemExit(f"--evidence must be a JSON array: {exc}")
        if not isinstance(parsed, list):
            raise SystemExit("--evidence must be a JSON array")
        evidence.extend(parsed)
    evidence.extend({"type": "url", "url": url, "verified": True} for url in args.evidence_url)
    evidence.extend({"type": "file", "path": path, "verified": True} for path in args.evidence_path)
    evidence.extend({"type": "note", "note": note} for note in args.evidence_note)
    return evidence or None


def main():
    parser = argparse.ArgumentParser(description="Use PerkOS technology APIs from OpenClaw/Hermes agents.")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("manifest")
    sub.add_parser("x402-policy")
    q = sub.add_parser("query")
    q.add_argument("query", nargs="+", help="Question/context query")
    q.add_argument("--limit", type=int, default=int(os.environ.get("KNOWLEDGE_LIMIT", "5")))
    q.add_argument("--create-request-on-miss", default=None)
    q.add_argument("--desired-output", default=None)
    q.add_argument("--quality-mode", default=os.environ.get("KNOWLEDGE_QUALITY_MODE"))
    q.add_argument("--min-confidence", type=int, default=int(os.environ["KNOWLEDGE_MIN_CONFIDENCE"]) if os.environ.get("KNOWLEDGE_MIN_CONFIDENCE") else None)
    q.add_argument("--require-validated", default=None)
    r = sub.add_parser("requests")
    r.add_argument("--status", default="open")
    r.add_argument("--limit", type=int, default=25)
    rc = sub.add_parser("request-create")
    rc.add_argument("query", nargs="+")
    rc.add_argument("--priority", default=None)
    rc.add_argument("--desired-output", default=None)
    claim = sub.add_parser("request-claim")
    claim.add_argument("request")
    claim.add_argument("--notes", default=None)
    fulfill = sub.add_parser("request-fulfill")
    fulfill.add_argument("request")
    fulfill.add_argument("--item-ids", required=True)
    fulfill.add_argument("--notes", default=None)
    validate = sub.add_parser("request-validate")
    validate.add_argument("request")
    validate.add_argument("--accepted", default="true")
    validate.add_argument("--notes", default=None)
    usage = sub.add_parser("llm-usage")
    usage.add_argument("--hours", type=int, default=24)
    usage.add_argument("--limit", type=int, default=10000)
    usage.add_argument("--agent", default=None)
    usage.add_argument("--self", action="store_true")
    submit = sub.add_parser("submit-research")
    submit.add_argument("--source", default=None)
    submit.add_argument("--visibility", default="private")
    submit.add_argument("--organization-id", default=os.environ.get("KNOWLEDGE_ORG_ID"))
    submit.add_argument("--contribution-type", default="research")
    submit.add_argument("--path", required=True)
    submit.add_argument("--title", default=None)
    submit.add_argument("--summary", default=None)
    submit.add_argument("--content", default=None)
    submit.add_argument("--evidence", default=None, help="JSON array of evidence objects")
    submit.add_argument("--evidence-url", action="append", default=[], help="Attach verified URL evidence; can be repeated")
    submit.add_argument("--evidence-path", action="append", default=[], help="Attach verified file/path evidence; can be repeated")
    submit.add_argument("--evidence-note", action="append", default=[], help="Attach note evidence; can be repeated")
    args = parser.parse_args()

    if args.cmd == "manifest":
        status, payload = request("GET", "/skill/manifest")
    elif args.cmd == "x402-policy":
        status, payload = request("GET", "/api/x402/policy")
    elif args.cmd == "query":
        create = None if args.create_request_on_miss is None else args.create_request_on_miss.lower() != "false"
        require_validated = None if args.require_validated is None else args.require_validated.lower() != "false"
        status, payload = request("POST", "/skill/query", {
            "query": " ".join(args.query),
            "limit": args.limit,
            "createRequestOnMiss": create,
            "desired_output": args.desired_output,
            "qualityMode": args.quality_mode,
            "minConfidence": args.min_confidence,
            "requireValidated": require_validated,
        })
    elif args.cmd == "requests":
        status, payload = request("GET", f"/knowledge/requests?status={urllib.parse.quote(args.status)}&limit={urllib.parse.quote(str(args.limit))}")
    elif args.cmd == "request-create":
        status, payload = request("POST", "/knowledge/requests", {"query": " ".join(args.query), "priority": args.priority, "desired_output": args.desired_output})
    elif args.cmd == "request-claim":
        status, payload = request("POST", f"/knowledge/requests/{urllib.parse.quote(args.request)}/claim", {"notes": args.notes}, auth=True)
    elif args.cmd == "request-fulfill":
        item_ids = [x.strip() for x in args.item_ids.split(",") if x.strip()]
        status, payload = request("POST", f"/knowledge/requests/{urllib.parse.quote(args.request)}/fulfill", {"research_item_ids": item_ids, "notes": args.notes}, auth=True)
    elif args.cmd == "request-validate":
        status, payload = request("POST", f"/knowledge/requests/{urllib.parse.quote(args.request)}/validate", {"accepted": args.accepted.lower() != "false", "validation_notes": args.notes}, auth=True)
    elif args.cmd == "llm-usage":
        token = os.environ.get("PERKOS_LLM_ADMIN_TOKEN") or os.environ.get("ADMIN_TOKEN") or ""
        if not token:
            raise SystemExit("PERKOS_LLM_ADMIN_TOKEN or ADMIN_TOKEN required")
        status, payload = llm_request(f"/admin/llm-usage?hours={urllib.parse.quote(str(args.hours))}&limit={urllib.parse.quote(str(args.limit))}", token)
        agent_id = args.agent or (current_agent_id() if args.self else "")
        if 200 <= status < 300 and agent_id:
            payload = filter_usage_for_agent(payload, agent_id)
    else:
        status, payload = request("POST", "/api/ingest/research", {
            "source": args.source,
            "visibility": args.visibility,
            "organization_id": args.organization_id,
            "contribution_type": args.contribution_type,
            "items": [{
                "path": args.path,
                "title": args.title or args.path,
                "summary": args.summary,
                "content": args.content,
                "contribution_type": args.contribution_type,
                "evidence": parse_evidence(args),
            }]
        }, auth=True)

    print(json.dumps(payload, indent=2, ensure_ascii=False))
    return 0 if 200 <= status < 300 else 1


if __name__ == "__main__":
    sys.exit(main())
