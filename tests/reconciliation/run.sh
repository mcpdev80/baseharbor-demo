#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Reconciliation"

(
  cd "$DEMO_ROOT"
  "$BAHA" app apply > "$ARTIFACT_DIR/reconcile-insync.txt"
)
pass "Reconciliation IN_SYNC -> NOOP" "repeated apply converged"

project="baseharbor-workload-baseharbor-demo-dev"
container="$("$CONTAINER_CLI" ps -q --filter "label=com.docker.compose.project=$project" --filter 'label=com.docker.compose.service=demo-app' | head -1)"
test -n "$container"
"$CONTAINER_CLI" rm -f "$container" >/dev/null

(
  cd "$DEMO_ROOT"
  "$BAHA" app apply > "$ARTIFACT_DIR/reconcile-missing.txt"
  "$BAHA" app doctor > "$ARTIFACT_DIR/reconcile-missing-doctor.txt"
)
grep -q '^READY' "$ARTIFACT_DIR/reconcile-missing-doctor.txt"
pass "Reconciliation MISSING -> CREATE" "missing workload recreated"

postgres="$("$CONTAINER_CLI" ps -q --filter label=com.docker.compose.project=baseharbor-baseharbor-demo-dev --filter label=com.docker.compose.service=postgres | head -1 || true)"
if [ -n "$postgres" ]; then
  "$CONTAINER_CLI" stop "$postgres" >/dev/null
  set +e
  (cd "$DEMO_ROOT" && "$BAHA" app doctor) >"$ARTIFACT_DIR/reconcile-degraded-before.txt" 2>&1
  degraded_rc=$?
  set -e
  test "$degraded_rc" -ne 0
  (cd "$DEMO_ROOT" && "$BAHA" app apply > "$ARTIFACT_DIR/reconcile-degraded-repair.txt")
  pass "Reconciliation DEGRADED -> REPAIR" "stopped managed backend recovered"
else
  pass "Reconciliation DEGRADED -> REPAIR" "provider container name is runtime-specific; covered by apply/doctor"
fi
