#!/usr/bin/env bash
set -euo pipefail
bash "$DEMO_ROOT/tests/agent/run.sh"
bash "$DEMO_ROOT/tests/mcp/run.sh"
