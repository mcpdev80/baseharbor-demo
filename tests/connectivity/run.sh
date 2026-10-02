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
pass "Companion Adoption" "second ordinary Compose app adopted through deterministic init + normal baha up"

(
  cd "$companion"
  "$BAHA" app inspect . -o json > "$ARTIFACT_DIR/companion-inspect-after-up.json"
  "$BAHA" status -o json > "$ARTIFACT_DIR/companion-status.json"
)
"$CONTAINER_CLI" ps -a --format '{{.ID}}	{{.Names}}	{{.Label "com.docker.compose.project"}}	{{.Label "com.docker.compose.service"}}' > "$ARTIFACT_DIR/connectivity-runtime-containers.tsv" 2>&1 || true

(
  cd "$DEMO_ROOT"
  if ! "$BAHA" connect demo/demo-app companion-app/companion-app > "$ARTIFACT_DIR/connect.txt" 2> "$ARTIFACT_DIR/connect.stderr.txt"; then
    cat "$ARTIFACT_DIR/connect.stderr.txt" >&2 || true
    cat "$ARTIFACT_DIR/connectivity-runtime-containers.tsv" >&2 || true
    exit 1
  fi
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
rm -rf "$companion_parent"
