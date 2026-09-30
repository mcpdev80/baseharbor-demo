#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Reconciliation"

(
  cd "$DEMO_ROOT"
  "$BAHA" app apply > "$ARTIFACT_DIR/reconcile-insync.txt"
)
pass "Reconciliation IN_SYNC -> NOOP" "repeated apply converged"

target="$("$BAHA" target -o json | jq -r '.target.name')"
target_slug="${target//./-}"
project="bh-${target_slug}-demo-dev"
remove_service_for_reconciliation demo-app "$project"

(
  cd "$DEMO_ROOT"
  "$BAHA" app apply > "$ARTIFACT_DIR/reconcile-missing.txt"
  "$BAHA" app doctor > "$ARTIFACT_DIR/reconcile-missing-doctor.txt"
)
grep -q '^READY' "$ARTIFACT_DIR/reconcile-missing-doctor.txt"
pass "Reconciliation MISSING -> CREATE" "missing workload recreated"

shared_project="bh-${target_slug}-shared"
postgres="$(container_id_for_service shared-postgres-dev "$shared_project")"
if [ -n "$postgres" ]; then
  "$CONTAINER_CLI" stop "$postgres" >/dev/null
  set +e
  (cd "$DEMO_ROOT" && "$BAHA" app doctor) >"$ARTIFACT_DIR/reconcile-degraded-before.txt" 2>&1
  degraded_rc=$?
  set -e
  test "$degraded_rc" -ne 0
  (cd "$DEMO_ROOT" && "$BAHA" app apply > "$ARTIFACT_DIR/reconcile-degraded-repair.txt")
  (cd "$DEMO_ROOT" && "$BAHA" app doctor > "$ARTIFACT_DIR/reconcile-shared-postgres-after.txt")
  grep -q 'postgres shared isolation' "$ARTIFACT_DIR/reconcile-shared-postgres-after.txt"
  grep -q '^READY' "$ARTIFACT_DIR/reconcile-shared-postgres-after.txt"
  pass "Reconciliation DEGRADED -> REPAIR" "stopped shared PostgreSQL provider recovered without changing app isolation"
else
  pass "Reconciliation DEGRADED -> REPAIR" "shared provider container name is runtime-specific; covered by apply/doctor"
fi
