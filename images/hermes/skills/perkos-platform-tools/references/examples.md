# perkos-platform-tools — examples

Copy-pasteable bash for the most common queries. Replace `$CONV_ID` with
the value from the `[PERKOS_CHAT:<id>]` marker in the system message.

The script path is always:
```
/opt/data/skills/perkos-platform-tools/scripts/perkos_tools.py
```

(That's where the entrypoint stages it from `/opt/perkos-skills/`.)

## Read the catalog

```bash
python3 /opt/data/skills/perkos-platform-tools/scripts/perkos_tools.py \
    list-tools --conv-id "$CONV_ID"
```

Returns the array of tool descriptors with input schemas. Useful when you
want to confirm a tool's shape before calling it.

## List the caller's agents

```bash
python3 /opt/data/skills/perkos-platform-tools/scripts/perkos_tools.py \
    call listMyAgents '{}' --conv-id "$CONV_ID"
```

Returns up to 50 agents owned by the caller, newest first.

## Read a specific runbook entry

```bash
python3 /opt/data/skills/perkos-platform-tools/scripts/perkos_tools.py \
    call getRunbookFor '{"topic":"04-lifecycle"}' --conv-id "$CONV_ID"
```

Topic can be the full slug (`04-lifecycle`) or just the stem
(`lifecycle`). The Tools API resolves either.

## Fuzzy search across the runbook

```bash
python3 /opt/data/skills/perkos-platform-tools/scripts/perkos_tools.py \
    call searchKnowledge '{"query":"fargate ecs","limit":3}' --conv-id "$CONV_ID"
```

Returns up to `limit` hits ranked by token-frequency + title bonus.
Follow up with `getRunbookFor` on the top hit for the full content.

## Look up a specific agent owned by the caller

```bash
python3 /opt/data/skills/perkos-platform-tools/scripts/perkos_tools.py \
    call getMyAgent '{"name":"MyBuilder"}' --conv-id "$CONV_ID"
```

Returns the full agent doc if and only if the caller owns it. Returns
`{ ok: false, errorClass: "NOT_FOUND" }` either way if the wallet
doesn't match — we never leak that an agent exists for another wallet.

## Explain a plugin from the catalog

```bash
python3 /opt/data/skills/perkos-platform-tools/scripts/perkos_tools.py \
    call explainPlugin '{"pluginId":"github"}' --conv-id "$CONV_ID"
```

## Common error patterns

```jsonc
// ok=false with NOT_FOUND — the slug doesn't exist
{
  "ok": false,
  "errorClass": "NOT_FOUND",
  "message": "Unknown topic. Available: 00-platform-overview, 01-deploy-modes, ..."
}

// ok=false with RATE_LIMITED — backoff for ~60s
{
  "ok": false,
  "errorClass": "RATE_LIMITED",
  "message": "Too many read calls. Backoff and retry."
}

// ok=false with BAD_INPUT — re-read SKILL.md, your args were wrong
{
  "ok": false,
  "errorClass": "BAD_INPUT",
  "message": "query: String must contain at least 2 character(s)"
}
```

## When the bridge is unreachable

If you see `perkos_tools: bridge unreachable at ...` on stderr (exit 3),
report it honestly: "the platform tools service isn't reachable from this
runtime right now". Don't fabricate an answer — say what you couldn't
verify.
