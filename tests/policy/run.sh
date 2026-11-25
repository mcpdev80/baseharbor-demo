#!/usr/bin/env bash
set -Eeuo pipefail

policy_unexpected_err() {
  local exit_code=$?
  local source_line="$1"
  local failed_command="$2"
  if [[ "$failed_command" == "("* ]]; then
    return "$exit_code"
  fi
  printf -v failure '%s:%s: assertion command failed (exit %s): %q' \
    "${BASH_SOURCE[0]}" "$source_line" "$exit_code" "$failed_command"
  printf 'policy gate unexpected ERR: %s\n' "$failure" >&2
  if [ -n "${DEMO_FAILURE_RECORD:-}" ]; then
    printf '%s\n' "$failure" > "$DEMO_FAILURE_RECORD"
  fi
  return "$exit_code"
}

trap 'policy_unexpected_err "$LINENO" "$BASH_COMMAND"' ERR

source "$DEMO_ROOT/tests/lib.sh"

# CI policy acceptance uses a disposable Keycloak X.509 identity for its
# operator login. Local runs retain the existing development/login behavior.
policy_environment=dev
if [ -n "${CI:-}" ]; then
  source "$DEMO_ROOT/tests/policy/operator-test-certificate.sh"
  trap operator_test_idp_cleanup EXIT
  operator_test_idp_setup
  policy_environment=test
fi

section "Environment and policy"
policy_org="$ARTIFACT_DIR/policy-organization"
mkdir -p "$policy_org"
cat > "$policy_org/organization.yaml" <<YAML
apiVersion: baseharbor.organization/v1
organization: demo-policy
operation: read
targets:
  dev:
    reference: local-dev
environments:
  $policy_environment: {}
profiles:
  demo-policy-reader:
    name: demo-policy-reader
    target: dev
    environment: $policy_environment
    operations: [read]
YAML
cat > "$policy_org/local-dev" <<'TARGET'
kind: target
name: local-dev
TARGET
(
  cd "$DEMO_ROOT"
  "$BAHA" config organization set --source local --location "$policy_org" --environment "$policy_environment" -o json \
    > "$ARTIFACT_DIR/policy-organization-active.json"
  "$BAHA" policy explain -e "$policy_environment" | tee "$ARTIFACT_DIR/policy-explain.txt"
  "$BAHA" policy check -e "$policy_environment" | tee "$ARTIFACT_DIR/policy-check.txt"
  if run_json policy-check "$BAHA" policy check -e "$policy_environment" -o json; then
    :
  else
    exit $?
  fi
)
pass "Policy" "explain + check + JSON"

before="$(sha256sum "$DEMO_ROOT/baseharbor.yaml" | awk '{print $1}')"
policy_result="$ARTIFACT_DIR/policy-${policy_environment}.json"
(
  cd "$DEMO_ROOT"
  "$BAHA" policy check -e "$policy_environment" -o json > "$policy_result"
)
after="$(sha256sum "$DEMO_ROOT/baseharbor.yaml" | awk '{print $1}')"
if [[ "$before" != "$after" ]]; then
  printf 'Environment Handling failed: baseharbor.yaml changed during policy check (before_sha256=%s after_sha256=%s)\n' \
    "$before" "$after" >&2
  exit 1
fi
actual_environment="$(jq -r 'if has("environment") then (.environment | tostring) else "<missing>" end' \
  "$policy_result" 2>/dev/null || printf '<invalid-json>')"
if [[ "$actual_environment" != "$policy_environment" ]]; then
  printf 'Environment Handling failed: expected JSON environment=%s, got %s; relevant fields: ' \
    "$policy_environment" \
    "$actual_environment" >&2
  jq -c '{environment, decision, allowed, status, result}' "$policy_result" >&2 || true
  exit 1
fi
pass "Environment Handling" "-e resolves deployment context without rewriting portable intent"
