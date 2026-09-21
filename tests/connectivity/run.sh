#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Cross-application connectivity"
companion="$DEMO_ROOT/companion-app"
rm -rf "$companion/.baseharbor" "$companion/baseharbor.yaml"

(
  cd "$companion"
  "$BAHA" app inspect . > "$ARTIFACT_DIR/companion-inspect.txt"
  "$BAHA" app init companion-app --environment dev
  "$BAHA" app init --input tls_mode=local --yes
  "$BAHA" app apply > "$ARTIFACT_DIR/companion-apply.txt"
  "$BAHA" app doctor > "$ARTIFACT_DIR/companion-doctor.txt"
)
grep -q '^READY' "$ARTIFACT_DIR/companion-doctor.txt"
pass "Companion Adoption" "second ordinary Compose app adopted independently"

(
  cd "$DEMO_ROOT"
  "$BAHA" connect baseharbor-demo/demo-app companion-app/companion-app > "$ARTIFACT_DIR/connect.txt"
  "$BAHA" connections > "$ARTIFACT_DIR/connections.txt"
)
grep -q 'baseharbor-demo' "$ARTIFACT_DIR/connections.txt"
grep -q 'companion-app' "$ARTIFACT_DIR/connections.txt"
pass "Cross-App Connectivity" "directed connection created"

(
  cd "$DEMO_ROOT"
  "$BAHA" disconnect baseharbor-demo/demo-app companion-app/companion-app > "$ARTIFACT_DIR/disconnect.txt"
  "$BAHA" connections > "$ARTIFACT_DIR/connections-after-disconnect.txt"
)
! grep -q 'baseharbor-demo.*companion-app' "$ARTIFACT_DIR/connections-after-disconnect.txt"
pass "Cross-App Isolation" "disconnect removed directed access"

(
  cd "$companion"
  "$BAHA" app destroy --yes
)
rm -rf "$companion/.baseharbor" "$companion/baseharbor.yaml"
