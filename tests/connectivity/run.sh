#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Cross-application connectivity"
companion_parent="$(mktemp -d "$DEMO_ROOT/.connectivity.XXXXXX")"
companion="$companion_parent/companion-app"
cp -a "$DEMO_ROOT/companion-app" "$companion"
cleanup_companion() {
  local status=$? cleanup_status=0
  set +e
  if [ -d "$companion" ]; then
    (
      cd "$companion"
      run_consented "$BAHA" app destroy --yes --full-reset >"$ARTIFACT_DIR/companion-cleanup.json" 2>"$ARTIFACT_DIR/companion-cleanup.stderr.txt"
    )
    cleanup_status=$?
  fi
  if [ "$cleanup_status" -eq 0 ]; then
    rm -rf "$companion_parent"
  else
    cat "$ARTIFACT_DIR/companion-cleanup.stderr.txt" >&2
    printf 'Companion cleanup failed; source retained at %s\n' "$companion" >&2
    [ "$status" -ne 0 ] || status="$cleanup_status"
  fi
  exit "$status"
}
trap cleanup_companion EXIT

(
  cd "$companion"
  "$BAHA" app inspect . > "$ARTIFACT_DIR/companion-inspect.txt"
  "$BAHA" app init --quick --json > "$ARTIFACT_DIR/companion-init.json"
  "$BAHA" up --yes > "$ARTIFACT_DIR/companion-up.txt"
  "$BAHA" app doctor > "$ARTIFACT_DIR/companion-doctor.txt"
)
grep -q '^READY' "$ARTIFACT_DIR/companion-doctor.txt"
companion_app_name="$(awk '/^[[:space:]]*name:[[:space:]]*/ {sub(/^[[:space:]]*name:[[:space:]]*/, ""); gsub(/["'\'' ]/, ""); print; exit}' "$companion/baseharbor.yaml")"
[ -n "$companion_app_name" ]
printf '%s\n' "$companion_app_name" > "$ARTIFACT_DIR/companion-app-name.txt"
pass "Companion Adoption" "second ordinary Compose app adopted through baha up"

(
  cd "$companion"
  "$BAHA" app inspect . -o json > "$ARTIFACT_DIR/companion-inspect-after-up.json"
  "$BAHA" status -o json > "$ARTIFACT_DIR/companion-status.json"
)
"$CONTAINER_CLI" ps -a --format '{{.ID}}	{{.Names}}	{{.Label "com.docker.compose.project"}}	{{.Label "com.docker.compose.service"}}' > "$ARTIFACT_DIR/connectivity-runtime-containers.tsv" 2>&1 || true

(
  cd "$DEMO_ROOT"
  if ! "$BAHA" connect demo/demo-app "$companion_app_name/companion-app" > "$ARTIFACT_DIR/connect.txt" 2> "$ARTIFACT_DIR/connect.stderr.txt"; then
    cat "$ARTIFACT_DIR/connect.stderr.txt" >&2 || true
    cat "$ARTIFACT_DIR/connectivity-runtime-containers.tsv" >&2 || true
    exit 1
  fi
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
assert_no_grep_match -q "demo.*$companion_app_name" "$ARTIFACT_DIR/connections-after-disconnect.txt"
pass "Cross-App Isolation" "disconnect removed directed access"

(
  cd "$companion"
  run_consented "$BAHA" app destroy --yes --full-reset >"$ARTIFACT_DIR/companion-destroy.json" 2>"$ARTIFACT_DIR/companion-destroy.stderr.txt"
)
trap - EXIT
rm -rf "$companion_parent"
