#!/usr/bin/env bash
set -euo pipefail
fixture="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/recovery-evidence-v1.json"
jq -e '
  .contract_version=="v1" and
  .schema_version=="v1" and
  any(.recovery.contributors[]; .state_class=="database.sql" and .verified==true) and
  any(.recovery.contributors[]; .state_class=="secrets" and .verified==true) and
  any(.recovery.contributors[]; .state_class=="object-storage.s3" and .verified==true) and
  any(.recovery.contributors[]; .state_class=="workload.storage" and .verified==true) and
  any(.recovery.contributors[]; .state_class=="observability.logs" and .verified==true) and
  any(.audit_events[]; .operation=="restore" and .outcome=="success") and
  any(.observed_state[]; .id=="status:postgres/isolation" and .status=="ready") and
  any(.verified_result[]; .id=="doctor:postgres shared isolation" and .status=="verified")
' "$fixture" >/dev/null
! grep -Eqi '(password|secret|token|access[_-]?key)[=:][^[:space:]]+' "$fixture"
printf 'PASS  Recovery evidence contract\n'
