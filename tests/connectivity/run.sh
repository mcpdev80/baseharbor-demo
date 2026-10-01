#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Cross-application connectivity"
companion_parent="$(mktemp -d)"
companion="$companion_parent/companion-app"
cp -a "$DEMO_ROOT/companion-app" "$companion"

cleanup_companion() {
  set +e
  if [ -d "$companion" ]; then
    (
      cd "$companion"
      "$BAHA" app destroy --yes >/dev/null 2>&1 || true
    )
  fi
  rm -rf "$companion_parent"
}
trap cleanup_companion EXIT

(
  cd "$companion"
  "$BAHA" app inspect . > "$ARTIFACT_DIR/companion-inspect.txt"
  "$BAHA" up --yes > "$ARTIFACT_DIR/companion-up.txt"
  "$BAHA" app doctor > "$ARTIFACT_DIR/companion-doctor.txt"
)
grep -q '^READY' "$ARTIFACT_DIR/companion-doctor.txt"
companion_app_name="$(awk '/^[[:space:]]*name:[[:space:]]*/ {sub(/^[[:space:]]*name:[[:space:]]*/, ""); gsub(/["'\'' ]/, ""); print; exit}' "$companion/baseharbor.yaml")"
[ -n "$companion_app_name" ]
printf '%s\n' "$companion_app_name" > "$ARTIFACT_DIR/companion-app-name.txt"
pass "Companion Adoption" "second ordinary Compose app adopted through baha up"

(
  cd "$DEMO_ROOT"
  "$BAHA" connect demo/demo-app "$companion_app_name/companion-app" > "$ARTIFACT_DIR/connect.txt"
  "$BAHA" connections > "$ARTIFACT_DIR/connections.txt"
)
grep -q 'demo' "$ARTIFACT_DIR/connections.txt"
grep -q "$companion_app_name" "$ARTIFACT_DIR/connections.txt"
pass "Cross-App Connectivity" "directed connection created"

(
  cd "$DEMO_ROOT"
  "$BAHA" disconnect demo/demo-app "$companion_app_name/companion-app" > "$ARTIFACT_DIR/disconnect.txt"
  "$BAHA" connections > "$ARTIFACT_DIR/connections-after-disconnect.txt"
)
! grep -q "demo.*$companion_app_name" "$ARTIFACT_DIR/connections-after-disconnect.txt"
pass "Cross-App Isolation" "disconnect removed directed access"

(
  cd "$companion"
  "$BAHA" app destroy --yes
)
trap - EXIT
rm -rf "$companion_parent"
