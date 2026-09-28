#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Recovery verification"

test -s "$ARTIFACT_DIR/recovery-evidence-after-restore.json"
test -s "$ARTIFACT_DIR/restore-doctor.txt"

grep -q '^READY' "$ARTIFACT_DIR/restore-doctor.txt"

jq -e '
  any(.recovery.contributors[]; .state_class=="database.sql" and .verified==true) and
  any(.recovery.contributors[]; .state_class=="secrets" and .verified==true) and
  any(.recovery.contributors[]; .state_class=="object-storage.s3" and .verified==true) and
  any(.recovery.contributors[]; .state_class=="workload.storage" and .verified==true) and
  any(.recovery.contributors[]; .state_class=="observability.logs" and .verified==true) and
  any(.audit_events[]; .operation=="restore" and .outcome=="success") and
  any(.observed[]; .id=="status:postgres/isolation" and .status=="ready") and
  any(.verified[]; .id=="doctor:postgres shared isolation" and .status=="verified")
' "$ARTIFACT_DIR/recovery-evidence-after-restore.json" >/dev/null

assert_no_secret_leak "$ARTIFACT_DIR/recovery-evidence-after-restore.json"
pass "Recovery Verification" "restored state, isolation evidence and restore audit remain verified"
