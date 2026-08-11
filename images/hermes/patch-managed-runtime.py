#!/usr/bin/env python3
"""Apply narrow, fail-fast PerkOS behavior patches to upstream Hermes."""

from pathlib import Path


GATEWAY_RUN = Path("/opt/hermes/gateway/run.py")
FIRST_MESSAGE_GUARDS = (
    "if not history and not await self.async_session_store.has_any_sessions():",
    "if not history and not self.session_store.has_any_sessions():",
)
HELPER_ANCHOR = "logger = logging.getLogger(__name__)"
HELPER = """

def _perkos_env_flag_disabled(name: str) -> bool:
    \"\"\"Return true when a PerkOS-managed upstream behavior is disabled.\"\"\"
    return os.getenv(name, \"\").strip().lower() in {\"1\", \"true\", \"yes\", \"on\"}
"""


def replace_exactly_once(source: str, needle: str, replacement: str, label: str) -> str:
    count = source.count(needle)
    if count != 1:
        raise RuntimeError(
            f"{label}: expected exactly one upstream anchor, found {count}; "
            "review the Hermes update before publishing this image"
        )
    return source.replace(needle, replacement, 1)


def patch_source(source: str) -> str:
    source = replace_exactly_once(
        source,
        HELPER_ANCHOR,
        HELPER_ANCHOR + HELPER,
        "managed first-message helper",
    )

    matches = [guard for guard in FIRST_MESSAGE_GUARDS if source.count(guard) == 1]
    if len(matches) != 1:
        raise RuntimeError(
            "managed first-message guard: expected exactly one supported upstream "
            f"anchor, found {len(matches)}; review the Hermes update before publishing "
            "this image"
        )
    guard = matches[0]
    condition = guard.removeprefix("if ").removesuffix(":")
    managed_guard = f'''if (
            not _perkos_env_flag_disabled("PERKOS_DISABLE_FIRST_MESSAGE_ONBOARDING")
            and {condition}
        ):'''
    return replace_exactly_once(
        source,
        guard,
        managed_guard,
        "managed first-message guard",
    )


if __name__ == "__main__":
    source = GATEWAY_RUN.read_text(encoding="utf-8")
    GATEWAY_RUN.write_text(patch_source(source), encoding="utf-8")
