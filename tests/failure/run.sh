#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Failure and secret leak cases"
for file in "$ARTIFACT_DIR"/*.txt "$ARTIFACT_DIR"/*.json; do
  [ -e "$file" ] || continue
  assert_no_secret_leak "$file"
done
pass "Secret Leak Checks" "no acceptance secret in captured output"

set +e
(
  cd "$DEMO_ROOT"
  BASEHARBOR_PROVIDER_PROMETHEUS_SCOPE=external "$BAHA" app apply
) >"$ARTIFACT_DIR/unsupported-placement.txt" 2>&1
rc=$?
set -e
test "$rc" -ne 0
pass "Unsupported -> Blocked" "unsupported provider placement failed closed"
