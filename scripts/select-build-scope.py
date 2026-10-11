#!/usr/bin/env python3
"""Select a bridge-only release; never provision runtimes on incomplete input."""
import os
from pathlib import Path
import re
import subprocess
import sys


BRIDGE_FILES = frozenset({
    ".github/workflows/build-push-ecr.yml",
    ".github/workflows/unit-tests.yml",
    "deploy/perkos-assistant/docker-compose.yml",
    "scripts/select-build-scope.py",
    "scripts/publish-a2a-native.sh",
    "docs/plans/2026-10-11-a2a-consumer-release-design.md",
})


def scope_for_paths(paths):
    if not paths:
        raise ValueError("release diff is empty")
    return "bridge" if all(
        path in BRIDGE_FILES or path.startswith((
            "images/perkos-a2a-bridge/", "tests/perkos-a2a-bridge/"
        )) for path in paths
    ) else "all"


def select_scope(event, requested, before, head):
    if event == "workflow_dispatch":
        if requested not in {"all", "bridge"}:
            raise ValueError("manual release scope must be all or bridge")
        return requested
    if event != "push":
        raise ValueError("unsupported release event")
    for revision in (before, head):
        if not re.fullmatch(r"[0-9a-fA-F]{40}", revision or "") or set(revision) == {"0"}:
            raise ValueError("release requires an existing before and head commit")
    # diff exits nonzero when either commit is missing; do not fall back to all.
    result = subprocess.run(
        ["git", "diff", "--no-renames", "--name-only", "-z", before, head, "--"],
        check=True, capture_output=True,
    )
    paths = result.stdout.decode("utf-8").rstrip("\0").split("\0") if result.stdout else []
    return scope_for_paths(paths)


def main():
    try:
        scope = select_scope(
            os.environ.get("RELEASE_EVENT", ""),
            os.environ.get("RELEASE_SCOPE", ""),
            os.environ.get("RELEASE_BEFORE", ""),
            os.environ.get("RELEASE_HEAD", ""),
        )
        with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
            output.write(f"scope={scope}\n")
        print(f"Release scope: {scope}")
    except (ValueError, KeyError, OSError, UnicodeError, subprocess.CalledProcessError):
        # No commit/path/credential dumps in release logs.
        print("Cannot determine release scope; no images will be published.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
