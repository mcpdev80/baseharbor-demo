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

workload:
  compose: compose.yaml
  services:
    - demo-app

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

logs:
  collect:
    - application

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

(
  cd "$DEMO_ROOT"
  "$BAHA" up --control-plane-only --yes | tee "$ARTIFACT_DIR/control-plane-bootstrap.txt"
  "$BAHA" openbao bootstrap --recovery-file "$ARTIFACT_DIR/openbao-recovery.json" | tee "$ARTIFACT_DIR/openbao-bootstrap.txt"
  "$BAHA" openbao status | tee "$ARTIFACT_DIR/openbao-status.txt"
)
grep -q "AppRole login succeeded" "$ARTIFACT_DIR/openbao-status.txt"
pass "Control Plane Bootstrap" "control plane and OpenBao prepared through the public baha up flow"
