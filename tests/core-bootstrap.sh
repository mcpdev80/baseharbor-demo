#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

core_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/baseharbor-core-bootstrap.XXXXXX")"
trap 'rm -rf "$core_root"' EXIT
(
  cd "$core_root"
  run_consented "$BAHA" up --yes >"$ARTIFACT_DIR/core-bootstrap-up.txt" 2>&1 || {
    cat "$ARTIFACT_DIR/core-bootstrap-up.txt" >&2
    exit 1
  }
  "$BAHA" doctor >"$ARTIFACT_DIR/core-bootstrap-doctor.txt"
  grep -q '^READY' "$ARTIFACT_DIR/core-bootstrap-doctor.txt"
)
