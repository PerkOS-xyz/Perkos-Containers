import os

from . import schemas, tools


def _has_ingest_token() -> bool:
    """Provider/write tools only work with a provider ingest token."""
    return bool(os.environ.get("KNOWLEDGE_INGEST_TOKEN"))


def register(ctx):
    # --- Read tools (always available) ---
    ctx.register_tool(
        name="perkos_knowledge_query",
        toolset="perkos-knowledge",
        schema=schemas.PERKOS_KNOWLEDGE_QUERY,
        handler=tools.perkos_knowledge_query,
    )
    ctx.register_tool(
        name="perkos_skill_manifest",
        toolset="perkos-knowledge",
        schema=schemas.PERKOS_SKILL_MANIFEST,
        handler=tools.perkos_skill_manifest,
    )
    ctx.register_tool(
        name="perkos_x402_policy",
        toolset="perkos-knowledge",
        schema=schemas.PERKOS_X402_POLICY,
        handler=tools.perkos_x402_policy,
    )
    ctx.register_tool(
        name="perkos_knowledge_requests_list",
        toolset="perkos-knowledge",
        schema=schemas.PERKOS_KNOWLEDGE_REQUESTS_LIST,
        handler=tools.perkos_knowledge_requests_list,
    )
    ctx.register_tool(
        name="perkos_knowledge_request_create",
        toolset="perkos-knowledge",
        schema=schemas.PERKOS_KNOWLEDGE_REQUEST_CREATE,
        handler=tools.perkos_knowledge_request_create,
    )

    # --- Provider / write tools (gated on KNOWLEDGE_INGEST_TOKEN) ---
    # mirrors the OpenClaw `toolMetadata.optional` markers and avoids the model
    # calling tools that would 401 without an onboarded provider token.
    ctx.register_tool(
        name="perkos_knowledge_request_claim",
        toolset="perkos-knowledge",
        schema=schemas.PERKOS_KNOWLEDGE_REQUEST_CLAIM,
        handler=tools.perkos_knowledge_request_claim,
        check_fn=_has_ingest_token,
    )
    ctx.register_tool(
        name="perkos_knowledge_request_fulfill",
        toolset="perkos-knowledge",
        schema=schemas.PERKOS_KNOWLEDGE_REQUEST_FULFILL,
        handler=tools.perkos_knowledge_request_fulfill,
        check_fn=_has_ingest_token,
    )
    ctx.register_tool(
        name="perkos_knowledge_request_validate",
        toolset="perkos-knowledge",
        schema=schemas.PERKOS_KNOWLEDGE_REQUEST_VALIDATE,
        handler=tools.perkos_knowledge_request_validate,
        check_fn=_has_ingest_token,
    )
    ctx.register_tool(
        name="perkos_knowledge_submit_research",
        toolset="perkos-knowledge",
        schema=schemas.PERKOS_KNOWLEDGE_SUBMIT_RESEARCH,
        handler=tools.perkos_knowledge_submit_research,
        check_fn=_has_ingest_token,
    )
