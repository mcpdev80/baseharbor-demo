#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Pristine repository and adoption"
clean_generated_state
test ! -e "$DEMO_ROOT/baseharbor.yaml"
test ! -e "$DEMO_ROOT/.baseharbor"

before="$(git -C "$DEMO_ROOT" status --porcelain --untracked-files=all)"
"$BAHA" app inspect "$DEMO_ROOT" | tee "$ARTIFACT_DIR/inspect.txt"
"$BAHA" app inspect "$DEMO_ROOT" -o json > "$ARTIFACT_DIR/inspect.json"
jq -e . "$ARTIFACT_DIR/inspect.json" >/dev/null
after="$(git -C "$DEMO_ROOT" status --porcelain --untracked-files=all)"
test "$before" = "$after"
pass "Repository Inspection" "read-only human + JSON"

set +e
(
  cd "$DEMO_ROOT"
  "$BAHA" app init --quick
) >"$ARTIFACT_DIR/init-quick-ambiguous.txt" 2>&1
quick_rc=$?
set -e
test "$quick_rc" -ne 0
grep -q "multiple Compose files were detected" "$ARTIFACT_DIR/init-quick-ambiguous.txt"
test ! -e "$DEMO_ROOT/baseharbor.yaml"
pass "Application Init Quick Ambiguity Gate" "multiple Compose candidates fail closed without guessing"

clean_generated_state
(
  cd "$DEMO_ROOT"
  "$BAHA" app init baseharbor-demo     --environment dev     --postgres     --redis     --s3-bucket uploads     --require-secret APP_SECRET
  "$BAHA" app init --input tls_mode=local --yes
)

cat >> "$DEMO_ROOT/baseharbor.yaml" <<'EOF'

metrics:
  sources:
    - name: application
      service: demo-app
      port: 8080
      path: /metrics

telemetry:
  otlp:
    signals:
      - traces

runtime:
  permissions:
    - capability: object-storage.s3/v1
      services:
        - demo-app
      operations:
        - runtime.create
        - runtime.get
        - runtime.delete
EOF

pass "Application Init Deterministic" "full portable contract built by CLI plus documented intent"

(
  cd "$DEMO_ROOT"
  "$BAHA" plan | tee "$ARTIFACT_DIR/plan.txt"
  run_json plan "$BAHA" plan -o json
)
pass "Plan" "human + JSON"

# First startup is expected to fail closed because APP_SECRET is required.
set +e
(
  cd "$DEMO_ROOT"
  BASEHARBOR_METRICS_ENABLED=true BASEHARBOR_LOGS_ENABLED=true BASEHARBOR_TRACES_ENABLED=true     "$BAHA" up --yes
) >"$ARTIFACT_DIR/up-missing-secret.txt" 2>&1
rc=$?
set -e
test "$rc" -ne 0
pass "Required Secret Gate" "missing secret failed closed"

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
