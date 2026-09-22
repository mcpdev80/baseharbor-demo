#!/usr/bin/env bash
set -euo pipefail

DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEMO_ROOT
export ARTIFACT_DIR="${ARTIFACT_DIR:-$DEMO_ROOT/artifacts}"
export BASEHARBOR_INSTALL_DIR="${BASEHARBOR_INSTALL_DIR:-$DEMO_ROOT/.tools/bin}"
mkdir -p "$ARTIFACT_DIR" "$BASEHARBOR_INSTALL_DIR"
: > "$ARTIFACT_DIR/results.tsv"
: > "$ARTIFACT_DIR/groups.tsv"

if [ -n "${BASEHARBOR_SOURCE_REF:-}" ]; then
  export BASEHARBOR_RUNTIME_IMAGE=baseharbor-runtime:demo-candidate
fi
bash "$DEMO_ROOT/scripts/install-baseharbor.sh"
export BAHA="$BASEHARBOR_INSTALL_DIR/baha"
export BASEHARBOR_STATE_DIR="${BASEHARBOR_STATE_DIR:-/tmp/baseharbor-demo-platform-state}"
export BASEHARBOR_TEST_RUNTIME="${BASEHARBOR_TEST_RUNTIME:-docker}"
command -v "$BASEHARBOR_TEST_RUNTIME" >/dev/null 2>&1

cleanup() {
  status=$?
  set +e
  cd "$DEMO_ROOT"
  "$BAHA" app destroy --yes >/dev/null 2>&1 || true
  cd "$DEMO_ROOT/companion-app"
  "$BAHA" app destroy --yes >/dev/null 2>&1 || true
  "$BASEHARBOR_TEST_RUNTIME" ps -q | xargs -r "$BASEHARBOR_TEST_RUNTIME" unpause >/dev/null 2>&1
  exit "$status"
}
trap cleanup EXIT

rm -rf "$BASEHARBOR_STATE_DIR"

declare -A requested=()
declare -A selected=()

add_group() {
  case "$1" in
    init|lifecycle|policy|capabilities|connectivity|security|reconciliation|machine|failure|recovery)
      requested["$1"]=1
      ;;
    *)
      echo "Unknown demo acceptance group: $1" >&2
      exit 2
      ;;
  esac
}

if [ "$#" -eq 0 ] && [ -z "${DEMO_GROUPS:-}" ]; then
  for group in init lifecycle policy capabilities connectivity security reconciliation machine failure recovery; do
    requested["$group"]=1
  done
else
  if [ -n "${DEMO_GROUPS:-}" ]; then
    IFS=',' read -r -a env_groups <<< "$DEMO_GROUPS"
    for group in "${env_groups[@]}"; do
      add_group "$group"
    done
  fi
  for group in "$@"; do
    add_group "$group"
  done
fi

for group in "${!requested[@]}"; do
  case "$group" in
    init)
      selected[init]=1
      ;;
    lifecycle)
      selected[init]=1
      selected[lifecycle]=1
      ;;
    policy)
      selected[init]=1
      selected[policy]=1
      ;;
    security)
      selected[init]=1
      selected[security]=1
      ;;
    machine)
      selected[init]=1
      selected[machine]=1
      ;;
    capabilities|connectivity|reconciliation|failure|recovery)
      selected[init]=1
      selected[lifecycle]=1
      selected["$group"]=1
      ;;
  esac
done

run_group() {
  case "$1" in
    init)
      bash "$DEMO_ROOT/tests/init/run.sh"
      ;;
    lifecycle)
      bash "$DEMO_ROOT/tests/lifecycle/run.sh"
      ;;
    policy)
      bash "$DEMO_ROOT/tests/policy/run.sh"
      ;;
    capabilities)
      bash "$DEMO_ROOT/tests/capabilities/run.sh"
      ;;
    connectivity)
      bash "$DEMO_ROOT/tests/connectivity/run.sh"
      ;;
    security)
      bash "$DEMO_ROOT/tests/security/run.sh"
      ;;
    reconciliation)
      bash "$DEMO_ROOT/tests/reconciliation/run.sh"
      ;;
    machine)
      bash "$DEMO_ROOT/tests/agent/run.sh" || return $?
      bash "$DEMO_ROOT/tests/mcp/run.sh"
      ;;
    failure)
      bash "$DEMO_ROOT/tests/failure/run.sh"
      ;;
    recovery)
      bash "$DEMO_ROOT/tests/backup-restore/run.sh"
      ;;
  esac
}

for group in init lifecycle policy capabilities connectivity security reconciliation machine failure recovery; do
  if [ "${selected[$group]:-0}" = "1" ]; then
    printf '\n>>> demo-%s\n' "$group"
    if run_group "$group"; then
      printf '%s\tPASS\tselected acceptance group passed\n' "$group" >> "$ARTIFACT_DIR/groups.tsv"
    else
      rc=$?
      printf '%s\tFAIL\tselected acceptance group failed\n' "$group" >> "$ARTIFACT_DIR/groups.tsv"
      bash "$DEMO_ROOT/scripts/report.sh" "$ARTIFACT_DIR/results.tsv"
      exit "$rc"
    fi
  fi
done

bash "$DEMO_ROOT/scripts/report.sh" "$ARTIFACT_DIR/results.tsv"
trap - EXIT
cleanup
