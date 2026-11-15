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
  "$BAHA" policy check -e dev -o json > "$ARTIFACT_DIR/policy-dev.json"
)
after="$(sha256sum "$DEMO_ROOT/baseharbor.yaml" | awk '{print $1}')"
if [[ "$before" != "$after" ]]; then
  printf 'Environment Handling failed: baseharbor.yaml changed during policy check (before_sha256=%s after_sha256=%s)\n' \
    "$before" "$after" >&2
  exit 1
fi
actual_environment="$(jq -r 'if has("environment") then (.environment | tostring) else "<missing>" end' \
  "$ARTIFACT_DIR/policy-dev.json" 2>/dev/null || printf '<invalid-json>')"
if [[ "$actual_environment" != "dev" ]]; then
  printf 'Environment Handling failed: expected JSON environment=dev, got %s; relevant fields: ' \
    "$actual_environment" >&2
  jq -c '{environment, decision, allowed, status, result}' "$ARTIFACT_DIR/policy-dev.json" >&2 || true
  exit 1
fi
pass "Environment Handling" "-e resolves deployment context without rewriting portable intent"
