#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Application lifecycle"

# First apply is expected to materialize runtime + secret scope, then fail closed
# because APP_SECRET is required before workload start.
set +e
(
  cd "$DEMO_ROOT"
  BASEHARBOR_METRICS_ENABLED=true BASEHARBOR_LOGS_ENABLED=true BASEHARBOR_TRACES_ENABLED=true     "$BAHA" app apply
) >"$ARTIFACT_DIR/apply-missing-secret.txt" 2>&1
rc=$?
set -e
cat "$ARTIFACT_DIR/apply-missing-secret.txt"
test "$rc" -ne 0
grep -q "required secrets check failed" "$ARTIFACT_DIR/apply-missing-secret.txt"
pass "Required Secret Gate" "first apply materialized secret scope and failed closed before workload start"

(
  cd "$DEMO_ROOT"
  printf '%s' 'acceptance-secret-value' | "$BAHA" app secret set APP_SECRET --stdin
  "$BAHA" app preflight | tee "$ARTIFACT_DIR/preflight.txt"
  BASEHARBOR_METRICS_ENABLED=true BASEHARBOR_LOGS_ENABLED=true BASEHARBOR_TRACES_ENABLED=true     "$BAHA" app apply | tee "$ARTIFACT_DIR/apply.txt"
  "$BAHA" status | tee "$ARTIFACT_DIR/status.txt"
  "$BAHA" doctor | tee "$ARTIFACT_DIR/doctor.txt"
  run_json status "$BAHA" status -o json
  run_json doctor "$BAHA" doctor -o json
)

grep -q '^READY' "$ARTIFACT_DIR/doctor.txt"
assert_no_secret_leak "$ARTIFACT_DIR/status.txt"
assert_no_secret_leak "$ARTIFACT_DIR/doctor.txt"
pass "Apply / Status / Doctor" "verified application lifecycle"

(
  cd "$DEMO_ROOT"
  "$BAHA" app down
  "$BAHA" app up
  "$BAHA" app doctor | tee "$ARTIFACT_DIR/doctor-after-resume.txt"
)
grep -q '^READY' "$ARTIFACT_DIR/doctor-after-resume.txt"
pass "Down / Up" "persistent runtime resumed"

(
  cd "$DEMO_ROOT"
  "$BAHA" app apply > "$ARTIFACT_DIR/apply-idempotent.txt"
)
pass "Idempotency" "second apply converged"
