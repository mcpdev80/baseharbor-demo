#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Capability config matrix"

python3 "$DEMO_ROOT/tests/config-matrix/contract_check.py"   --baha "$BAHA"   --demo-root "$DEMO_ROOT"   | tee "$ARTIFACT_DIR/config-matrix-contract.txt"

matrix_root="$(mktemp -d)"
cleanup_matrix() { rm -rf "$matrix_root"; }
trap cleanup_matrix EXIT

assert_bindings() {
  local case_id="$1"
  local expected_json
  expected_json="$(jq -c --arg id "$case_id" '.cases[] | select(.id == $id) | .expected_bindings' "$DEMO_ROOT/tests/config-matrix/cases.json")"
  local env_file="$ARTIFACT_DIR/config-matrix-$case_id-env.json"
  python3 - "$expected_json" "$env_file" <<'PY'
import json,sys
expected=set(json.loads(sys.argv[1]))
env=json.load(open(sys.argv[2]))
aliases={"REDIS_URL":{"REDIS_URL","VALKEY_URL"}}
for name in expected:
    choices=aliases.get(name,{name})
    if not any(choice in env for choice in choices):
        raise SystemExit(f"missing expected binding {name}")
phantom={
 "DATABASE_URL":{"DATABASE_URL"},
 "REDIS_URL":{"REDIS_URL","VALKEY_URL"},
 "S3_ENDPOINT":{"S3_ENDPOINT","AWS_ENDPOINT_URL"},
 "APP_SECRET":{"APP_SECRET"},
 "OIDC_ISSUER":{"OIDC_ISSUER"},
 "OTEL_EXPORTER_OTLP_ENDPOINT":{"OTEL_EXPORTER_OTLP_ENDPOINT"},
}
for logical,choices in phantom.items():
    wanted = logical in expected or (logical=="REDIS_URL" and "REDIS_URL" in expected)
    if not wanted and any(choice in env for choice in choices):
        raise SystemExit(f"phantom binding {logical}")
PY
}

run_runtime_case() {
  local case_id="$1"
  local port="$2"
  local case_root="$matrix_root/$case_id"
  mkdir -p "$case_root"
  cp -a "$DEMO_ROOT/demo-app" "$case_root/demo-app"
  python3 "$DEMO_ROOT/tests/config-matrix/render_runtime_compose.py" --matrix "$DEMO_ROOT/tests/config-matrix/cases.json" --case "$case_id" --output "$case_root/compose.yaml"
  python3 "$DEMO_ROOT/tests/config-matrix/render.py" --matrix "$DEMO_ROOT/tests/config-matrix/cases.json" --case "$case_id" --output "$case_root/baseharbor.yaml"

  (
    cd "$case_root"
    export DEMO_HTTPS_PORT="$port"
    "$BAHA" app preflight >"$ARTIFACT_DIR/config-matrix-$case_id-preflight.txt"
    "$BAHA" up --yes >"$ARTIFACT_DIR/config-matrix-$case_id-up.txt"
    "$BAHA" status -o json >"$ARTIFACT_DIR/config-matrix-$case_id-status.json"
    "$BAHA" doctor >"$ARTIFACT_DIR/config-matrix-$case_id-doctor.txt"
    "$BAHA" app env --format json >"$ARTIFACT_DIR/config-matrix-$case_id-env.json"
    jq -e '.state == "running"' "$ARTIFACT_DIR/config-matrix-$case_id-status.json" >/dev/null
    grep -q '^READY' "$ARTIFACT_DIR/config-matrix-$case_id-doctor.txt"
    assert_bindings "$case_id"

    "$BAHA" app down >"$ARTIFACT_DIR/config-matrix-$case_id-down.txt"
    "$BAHA" up --yes >"$ARTIFACT_DIR/config-matrix-$case_id-reup.txt"
    "$BAHA" doctor >"$ARTIFACT_DIR/config-matrix-$case_id-redoctor.txt"
    grep -q '^READY' "$ARTIFACT_DIR/config-matrix-$case_id-redoctor.txt"
    "$BAHA" app destroy --yes >"$ARTIFACT_DIR/config-matrix-$case_id-destroy.txt"
  )
  assert_no_secret_leak "$ARTIFACT_DIR/config-matrix-$case_id-status.json"
  assert_no_secret_leak "$ARTIFACT_DIR/config-matrix-$case_id-env.json"
}

# The full declarative matrix is always validated without mutation above.
# Runtime rotation intentionally covers only the two reduced profiles that prove
# absence/expansion and multi-capability composition. The normal demo suite owns
# the full-stack capability probes, so repeating every provider here would only
# rebuild the same containers again.
if [ -z "${DEMO_SUITE:-}" ]; then
  run_runtime_case workload-only 18180
  run_runtime_case developer-core 18181
  pass "Config Matrix" "13 contracts validated; representative reduced profiles converge, restart and destroy"
else
  pass "Config Matrix" "13 contracts validated without duplicate runtime startup"
fi
