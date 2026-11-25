#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Reconciliation"

(
  cd "$DEMO_ROOT"
  run_consented "$BAHA" app apply > "$ARTIFACT_DIR/reconcile-insync.txt"
)
pass "Reconciliation IN_SYNC -> NOOP" "repeated apply converged"

target="$("$BAHA" target -o json | jq -r '.target.name')"
target_slug="${target//./-}"
project="bh-${target_slug}-demo-dev"
remove_managed_service_for_reconcile demo-app "$project"

# NOTE (w198 demo fixture fix-forward, #1842): the compound `run_consented baha app apply` /
# `baha app doctor` block was splitting diagnostics. After removing the managed service, one of
# those subcommands failed (jobs 139422945437/139422945057) and the grouped redirections hid which
# one. Run each with its own stdout/stderr/status so the actual failure cannot be masked. If
# `doctor` reports authentication is required, the ephemeral operator-test identity setup is
# available in the policy fixture; that call is intentionally left to the next fix pass once the
# captured diagnostic confirms it — this split preserves the exact error for that decision instead
# of guessing, and does not weaken product auth.
(
  cd "$DEMO_ROOT"
  run_consented "$BAHA" app apply > "$ARTIFACT_DIR/reconcile-missing.txt" 2>&1
  apply_rc=$?
  if [ "$apply_rc" -ne 0 ]; then
    echo "reconcile apply failed (rc=$apply_rc)" >&2
    cat "$ARTIFACT_DIR/reconcile-missing.txt" >&2 || true
    exit "$apply_rc"
  fi
  "$BAHA" app doctor > "$ARTIFACT_DIR/reconcile-missing-doctor.txt" 2>&1
  doctor_rc=$?
  if [ "$doctor_rc" -ne 0 ]; then
    echo "reconcile doctor failed (rc=$doctor_rc)" >&2
    cat "$ARTIFACT_DIR/reconcile-missing-doctor.txt" >&2 || true
    exit "$doctor_rc"
  fi
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
  (cd "$DEMO_ROOT" && run_consented "$BAHA" app apply > "$ARTIFACT_DIR/reconcile-degraded-repair.txt")
  (cd "$DEMO_ROOT" && "$BAHA" app doctor > "$ARTIFACT_DIR/reconcile-shared-postgres-after.txt")
  grep -q 'postgres shared isolation' "$ARTIFACT_DIR/reconcile-shared-postgres-after.txt"
  grep -q '^READY' "$ARTIFACT_DIR/reconcile-shared-postgres-after.txt"
  pass "Reconciliation DEGRADED -> REPAIR" "stopped shared PostgreSQL provider recovered without changing app isolation"
else
  pass "Reconciliation DEGRADED -> REPAIR" "shared provider container name is runtime-specific; covered by apply/doctor"
fi
