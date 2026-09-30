#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Application lifecycle after guided adoption"

test -s "$DEMO_ROOT/baseharbor.yaml"

(
  cd "$DEMO_ROOT"
  "$BAHA" plan | tee "$ARTIFACT_DIR/plan.txt"
  run_json plan "$BAHA" plan -o json
  preflight_ok=false
  for attempt in 1 2 3; do
    if "$BAHA" app preflight | tee "$ARTIFACT_DIR/preflight.txt"; then
      preflight_ok=true
      break
    fi
    sleep 2
  done
  test "$preflight_ok" = true
  "$BAHA" status | tee "$ARTIFACT_DIR/status.txt"
  "$BAHA" doctor | tee "$ARTIFACT_DIR/doctor.txt"
)

grep -q '^READY' "$ARTIFACT_DIR/doctor.txt"
assert_no_secret_leak "$ARTIFACT_DIR/status.txt"
assert_no_secret_leak "$ARTIFACT_DIR/doctor.txt"
pass "Plan / Preflight / Status / Doctor" "advanced read-only diagnostics remain available after the normal happy path"

(
  cd "$DEMO_ROOT"
  "$BAHA" app down
  BASEHARBOR_TRACES_ENABLED=true "$BAHA" up | tee "$ARTIFACT_DIR/up-after-down.txt"
  "$BAHA" doctor | tee "$ARTIFACT_DIR/doctor-after-resume.txt"
)
grep -q '^READY' "$ARTIFACT_DIR/doctor-after-resume.txt"
pass "Down / Up" "recommended repository command resumes persistent runtime"

(
  cd "$DEMO_ROOT"
  BASEHARBOR_TRACES_ENABLED=true "$BAHA" up > "$ARTIFACT_DIR/up-idempotent.txt"
)
grep -Eq 'already READY|No changes|READY' "$ARTIFACT_DIR/up-idempotent.txt"
pass "Idempotency" "second baha up converged without manual repair"
