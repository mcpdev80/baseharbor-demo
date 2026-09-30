#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Capability configuration matrix"

matrix="$DEMO_ROOT/tests/config-matrix/cases.json"
renderer="$DEMO_ROOT/tests/config-matrix/render.py"
mode="${DEMO_MATRIX_MODE:-core}"
matrix_root="$(mktemp -d)"
trap 'rm -rf "$matrix_root"' EXIT

jq -e '
  .schema_version == "baseharbor.demo-config-matrix/v1" and
  (.cases | length >= 10) and
  ([.cases[].id] | length == (unique | length)) and
  all(.cases[];
    (.capabilities | type == "array") and
    (.expected_bindings | type == "array") and
    (.runtime == "always" or .runtime == "full")
  )
' "$matrix" >/dev/null

runtime_case_enabled() {
  local policy="$1"
  [ "$policy" = "always" ] || [ "$mode" = "full" ]
}

reset_case_target() {
  local target="$1"
  set +e
  "$BAHA" destroy --all --yes >/dev/null 2>&1
  set -e
  rm -rf "$XDG_CONFIG_HOME/baseharbor" "$XDG_DATA_HOME/baseharbor" "$XDG_DATA_HOME/baseharbor-recovery"
  "$BAHA" target create "$target"     --provider "$BASEHARBOR_TEST_RUNTIME"     --access "local-$BASEHARBOR_TEST_RUNTIME"     --reference local     --scope default     --default >/dev/null
  export BASEHARBOR_TARGET="$target"
}

assert_binding_projection() {
  local root="$1" case_id="$2"
  local expected_file="$ARTIFACT_DIR/config-matrix-$case_id-expected-bindings.txt"
  jq -r --arg id "$case_id" '.cases[] | select(.id == $id) | .expected_bindings[]' "$matrix" >"$expected_file"

  local env_files
  env_files="$(find "$XDG_DATA_HOME/baseharbor" -type f \( -name '*.env' -o -name 'runtime.env' \) -print 2>/dev/null || true)"
  local binding
  for binding in DATABASE_URL REDIS_URL S3_ENDPOINT S3_BUCKET APP_SECRET OIDC_ISSUER OIDC_CLIENT_ID OTEL_EXPORTER_OTLP_ENDPOINT; do
    if grep -Fxq "$binding" "$expected_file"; then
      if ! grep -hE "^${binding}=" $env_files >/dev/null 2>&1; then
        echo "matrix case $case_id: expected binding $binding was not projected" >&2
        return 1
      fi
    else
      if grep -hE "^${binding}=" $env_files >/dev/null 2>&1; then
        echo "matrix case $case_id: phantom binding $binding was projected" >&2
        return 1
      fi
    fi
  done
}

while IFS=$'\t' read -r case_id runtime_policy; do
  case_root="$matrix_root/$case_id"
  mkdir -p "$case_root"
  cp "$DEMO_ROOT/compose.yaml" "$case_root/compose.yaml"
  cp -a "$DEMO_ROOT/demo-app" "$case_root/demo-app"
  python3 "$renderer" --matrix "$matrix" --case "$case_id" --output "$case_root/baseharbor.yaml"

  (
    cd "$case_root"
    "$BAHA" app show -o json >/dev/null 2>&1 && {
      echo "app show unexpectedly accepted -o json; matrix should use plan for structured validation" >&2
      exit 1
    } || true
    "$BAHA" app plan -o json >"$ARTIFACT_DIR/config-matrix-$case_id-plan.json"
    jq -e --arg app "matrix-$case_id" '.application == $app' "$ARTIFACT_DIR/config-matrix-$case_id-plan.json" >/dev/null
  )

  if ! runtime_case_enabled "$runtime_policy"; then
    pass "Config Matrix $case_id" "contract rendered and planned; runtime coverage deferred to full release matrix"
    continue
  fi

  target="matrix-${BASEHARBOR_TEST_RUNTIME}-$case_id"
  reset_case_target "$target"

  (
    cd "$case_root"
    "$BAHA" --no-input up --yes >"$ARTIFACT_DIR/config-matrix-$case_id-up.txt" 2>&1
    "$BAHA" status -o json >"$ARTIFACT_DIR/config-matrix-$case_id-status.json"
    "$BAHA" doctor >"$ARTIFACT_DIR/config-matrix-$case_id-doctor.txt"
    jq -e '.ready == true' "$ARTIFACT_DIR/config-matrix-$case_id-status.json" >/dev/null
    grep -q '^READY' "$ARTIFACT_DIR/config-matrix-$case_id-doctor.txt"
  )

  assert_binding_projection "$case_root" "$case_id"

  (
    cd "$case_root"
    "$BAHA" app down --plain >/dev/null
    "$BAHA" app down --plain >/dev/null
    "$BAHA" --no-input up --yes >/dev/null
    "$BAHA" app destroy --yes >/dev/null
  )

  pass "Config Matrix $case_id" "plan -> up -> READY/status/doctor -> binding audit -> idempotent down -> up -> destroy"
done < <(jq -r '.cases[] | [.id,.runtime] | @tsv' "$matrix")

pass "Capability Config Matrix" "declarative reduced-contract matrix completed in mode=$mode"
