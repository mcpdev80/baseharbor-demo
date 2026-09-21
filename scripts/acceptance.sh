#!/usr/bin/env bash
set -euo pipefail

DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEMO_ROOT
export ARTIFACT_DIR="${ARTIFACT_DIR:-$DEMO_ROOT/artifacts}"
export BASEHARBOR_INSTALL_DIR="${BASEHARBOR_INSTALL_DIR:-$DEMO_ROOT/.tools/bin}"
mkdir -p "$ARTIFACT_DIR" "$BASEHARBOR_INSTALL_DIR"
: > "$ARTIFACT_DIR/results.tsv"

if [ -n "${BASEHARBOR_SOURCE_REF:-}" ]; then
  export BASEHARBOR_RUNTIME_IMAGE=baseharbor-runtime:demo-candidate
fi
bash "$DEMO_ROOT/scripts/install-baseharbor.sh"
export BAHA="$BASEHARBOR_INSTALL_DIR/baha"
export BASEHARBOR_STATE_DIR="${BASEHARBOR_STATE_DIR:-/tmp/baseharbor-demo-platform-state}"

cleanup() {
  status=$?
  set +e
  cd "$DEMO_ROOT"
  "$BAHA" app destroy --yes >/dev/null 2>&1 || true
  cd "$DEMO_ROOT/companion-app"
  "$BAHA" app destroy --yes >/dev/null 2>&1 || true
  docker ps -q | xargs -r docker unpause >/dev/null 2>&1
  exit "$status"
}
trap cleanup EXIT

rm -rf "$BASEHARBOR_STATE_DIR"

for test_script in \
  tests/lifecycle/run.sh \
  tests/policy/run.sh \
  tests/capabilities/run.sh \
  tests/security/run.sh \
  tests/reconciliation/run.sh \
  tests/connectivity/run.sh \
  tests/agent/run.sh \
  tests/mcp/run.sh \
  tests/failure/run.sh \
  tests/backup-restore/run.sh
do
  bash "$DEMO_ROOT/$test_script"
done

bash "$DEMO_ROOT/scripts/report.sh" "$ARTIFACT_DIR/results.tsv"
trap - EXIT
cleanup
