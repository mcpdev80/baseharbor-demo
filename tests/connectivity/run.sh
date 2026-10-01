#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Cross-application connectivity"
companion="$DEMO_ROOT/companion-app"
cleanup_companion() {
  set +e
  if [ -d "$companion" ]; then
    (
      cd "$companion"
      "$BAHA" app destroy --yes >/dev/null 2>&1 || true
    )
    rm -rf "$companion/.baseharbor" "$companion/baseharbor.yaml"
  fi
}
trap cleanup_companion EXIT
rm -rf "$companion/.baseharbor" "$companion/baseharbor.yaml"

(
  cd "$companion"
  "$BAHA" app inspect . > "$ARTIFACT_DIR/companion-inspect.txt"
  "$BAHA" app init --workload-compose compose.yaml --workload-service companion-app > "$ARTIFACT_DIR/companion-init.txt"
  "$BAHA" up --yes > "$ARTIFACT_DIR/companion-up.txt"
  "$BAHA" app doctor > "$ARTIFACT_DIR/companion-doctor.txt"
)
grep -q '^READY' "$ARTIFACT_DIR/companion-doctor.txt"
pass "Companion Adoption" "second ordinary Compose app adopted through deterministic init + normal baha up"

(
  cd "$DEMO_ROOT"
  "$BAHA" connect demo/demo-app companion-app/companion-app > "$ARTIFACT_DIR/connect.txt"
  "$BAHA" connections > "$ARTIFACT_DIR/connections.txt"
)
grep -q 'demo' "$ARTIFACT_DIR/connections.txt"
grep -q 'companion-app' "$ARTIFACT_DIR/connections.txt"
pass "Cross-App Connectivity" "directed connection created"

(
  cd "$DEMO_ROOT"
  "$BAHA" disconnect demo/demo-app companion-app/companion-app > "$ARTIFACT_DIR/disconnect.txt"
  "$BAHA" connections > "$ARTIFACT_DIR/connections-after-disconnect.txt"
)
! grep -q 'demo.*companion-app' "$ARTIFACT_DIR/connections-after-disconnect.txt"
pass "Cross-App Isolation" "disconnect removed directed access"

(
  cd "$companion"
  "$BAHA" app destroy --yes
)
trap - EXIT
rm -rf "$companion/.baseharbor" "$companion/baseharbor.yaml"
