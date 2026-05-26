#!/usr/bin/env bash
# Convenience runner for the perkos_tools.py unit suite.
# Designed to be called from CI or locally with no extra deps — uses
# nothing but Python's stdlib (urllib + http.server + unittest).
#
# Usage: ./tests/perkos-tools/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

python3 test_perkos_tools.py
