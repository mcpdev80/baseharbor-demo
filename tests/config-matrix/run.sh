#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Capability config matrix"

python3 "$DEMO_ROOT/tests/config-matrix/contract_check.py"   --baha "$BAHA"   --demo-root "$DEMO_ROOT"   | tee "$ARTIFACT_DIR/config-matrix-contract.txt"

matrix_root="$(mktemp -d)"
cleanup_matrix() {
  rm -rf "$matrix_root"
}
trap cleanup_matrix EXIT

run_runtime_case() {
  local case_id="$1"
  local port="$2"
  local case_root="$matrix_root/$case_id"
  mkdir -p "$case_root"
  python3 "$DEMO_ROOT/tests/config-matrix/render_runtime_compose.py" \
    --matrix "$DEMO_ROOT/tests/config-matrix/cases.json" \
    --case "$case_id" \
    --output "$case_root/compose.yaml"

  python3 "$DEMO_ROOT/tests/config-matrix/render.py"     --matrix "$DEMO_ROOT/tests/config-matrix/cases.json"     --case "$case_id"     --output "$case_root/baseharbor.yaml"

  (
    cd "$case_root"
    export DEMO_HTTP_PORT="$port"

    if ! "$BAHA" app preflight >"$ARTIFACT_DIR/config-matrix-$case_id-preflight.txt" 2>&1; then
      cat "$ARTIFACT_DIR/config-matrix-$case_id-preflight.txt" >&2
      return 1
    fi
    if ! "$BAHA" up --yes >"$ARTIFACT_DIR/config-matrix-$case_id-up.txt" 2>&1; then
      cat "$ARTIFACT_DIR/config-matrix-$case_id-up.txt" >&2
      return 1
    fi
    "$BAHA" status -o json >"$ARTIFACT_DIR/config-matrix-$case_id-status.json"
    "$BAHA" doctor >"$ARTIFACT_DIR/config-matrix-$case_id-doctor.txt"
    "$BAHA" app env --format json >"$ARTIFACT_DIR/config-matrix-$case_id-env.json"

    jq -e '.state == "running"' "$ARTIFACT_DIR/config-matrix-$case_id-status.json" >/dev/null
    grep -q '^READY' "$ARTIFACT_DIR/config-matrix-$case_id-doctor.txt"

    case "$case_id" in
      workload-only)
        jq -e '
          has("DATABASE_URL") | not
        ' "$ARTIFACT_DIR/config-matrix-$case_id-env.json" >/dev/null
        jq -e '
          has("REDIS_URL") | not
        ' "$ARTIFACT_DIR/config-matrix-$case_id-env.json" >/dev/null
        jq -e '
          has("VALKEY_URL") | not
        ' "$ARTIFACT_DIR/config-matrix-$case_id-env.json" >/dev/null
        jq -e '
          has("S3_ENDPOINT") | not
        ' "$ARTIFACT_DIR/config-matrix-$case_id-env.json" >/dev/null
        jq -e '
          has("APP_SECRET") | not
        ' "$ARTIFACT_DIR/config-matrix-$case_id-env.json" >/dev/null
        jq -e '
          has("OIDC_ISSUER") | not
        ' "$ARTIFACT_DIR/config-matrix-$case_id-env.json" >/dev/null
        jq -e '
          has("OTEL_EXPORTER_OTLP_ENDPOINT") | not
        ' "$ARTIFACT_DIR/config-matrix-$case_id-env.json" >/dev/null
        ;;
      developer-core)
        jq -e 'has("DATABASE_URL")' "$ARTIFACT_DIR/config-matrix-$case_id-env.json" >/dev/null
        jq -e '(has("REDIS_URL") or has("VALKEY_URL"))' "$ARTIFACT_DIR/config-matrix-$case_id-env.json" >/dev/null
        jq -e 'has("APP_SECRET") | not' "$ARTIFACT_DIR/config-matrix-$case_id-env.json" >/dev/null
        jq -e '
          any(.checks[]?; .name == "required-secret/APP_SECRET" and .ok == true and .state == "ready")
        ' "$ARTIFACT_DIR/config-matrix-$case_id-status.json" >/dev/null
        jq -e 'has("S3_ENDPOINT") | not' "$ARTIFACT_DIR/config-matrix-$case_id-env.json" >/dev/null
        jq -e 'has("OIDC_ISSUER") | not' "$ARTIFACT_DIR/config-matrix-$case_id-env.json" >/dev/null
        jq -e 'has("OTEL_EXPORTER_OTLP_ENDPOINT") | not' "$ARTIFACT_DIR/config-matrix-$case_id-env.json" >/dev/null
        ;;
    esac

    "$BAHA" app down >"$ARTIFACT_DIR/config-matrix-$case_id-down.txt"
    "$BAHA" up --yes >"$ARTIFACT_DIR/config-matrix-$case_id-reup.txt"
    "$BAHA" doctor >"$ARTIFACT_DIR/config-matrix-$case_id-redoctor.txt"
    grep -q '^READY' "$ARTIFACT_DIR/config-matrix-$case_id-redoctor.txt"
    "$BAHA" app destroy --yes >"$ARTIFACT_DIR/config-matrix-$case_id-destroy.txt"
  )

  assert_no_secret_leak "$ARTIFACT_DIR/config-matrix-$case_id-status.json"
  assert_no_secret_leak "$ARTIFACT_DIR/config-matrix-$case_id-env.json"
}

# Standalone execution additionally proves two reduced runtime profiles.
# Atomic pre-release executes this gate as a static contract/plan proof; real
# provider semantics are proven by their dedicated minimal Docker/Podman gates.
# This avoids starting provider containers merely to validate portable planning.
if [ -z "${DEMO_SUITE:-}" ]; then
  run_runtime_case workload-only 18180
  run_runtime_case developer-core 18181
  pass "Config Matrix" "all contracts planned; reduced runtime profiles converge, restart and destroy"
else
  pass "Config Matrix" "all reduced contracts planned without mutation; targeted runtime matrix is a pre-release prerequisite"
fi
