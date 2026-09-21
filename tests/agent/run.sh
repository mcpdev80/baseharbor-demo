#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Agent machine contract"
(
  cd "$DEMO_ROOT"
  "$BAHA" agent describe -o json > "$ARTIFACT_DIR/agent.json"
)
jq -e '.contract_version=="v1"' "$ARTIFACT_DIR/agent.json" >/dev/null
! grep -Eqi '"(shell|docker|exec)"' "$ARTIFACT_DIR/agent.json"
assert_no_secret_leak "$ARTIFACT_DIR/agent.json"
pass "Agent Interface" "machine contract v1, bounded and secret-safe"
