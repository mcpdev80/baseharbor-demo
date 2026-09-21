#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Environment and policy"
(
  cd "$DEMO_ROOT"
  "$BAHA" policy explain -e dev | tee "$ARTIFACT_DIR/policy-explain.txt"
  "$BAHA" policy check -e dev | tee "$ARTIFACT_DIR/policy-check.txt"
  run_json policy-check "$BAHA" policy check -e dev -o json
)
pass "Policy" "explain + check + JSON"

before="$(sha256sum "$DEMO_ROOT/baseharbor.yaml" | awk '{print $1}')"
(
  cd "$DEMO_ROOT"
  "$BAHA" status -e dev -o json > "$ARTIFACT_DIR/status-dev.json"
)
after="$(sha256sum "$DEMO_ROOT/baseharbor.yaml" | awk '{print $1}')"
test "$before" = "$after"
pass "Environment Handling" "-e does not rewrite portable intent"
