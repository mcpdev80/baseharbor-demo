#!/usr/bin/env bash
set -euo pipefail

: "${BASEHARBOR_SOURCE_REF:?BASEHARBOR_SOURCE_REF is required}"
: "${BASEHARBOR_TEST_RUNTIME:?BASEHARBOR_TEST_RUNTIME is required}"
: "${ARTIFACT_DIR:?ARTIFACT_DIR is required}"
: "${DEMO_ROOT:?DEMO_ROOT is required}"

export BASEHARBOR_INSTALL_DIR="${BASEHARBOR_INSTALL_DIR:-$DEMO_ROOT/.tools/bin}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/tmp/baseharbor-debug-reconcile/config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-/tmp/baseharbor-debug-reconcile/data}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/baseharbor-debug-reconcile/cache}"
export BASEHARBOR_TARGET="${BASEHARBOR_TARGET:-debug-reconcile-${BASEHARBOR_TEST_RUNTIME}}"

rm -rf "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR"

bash "$DEMO_ROOT/scripts/install-baseharbor.sh" >"$ARTIFACT_DIR/install.txt" 2>&1
BAHA="$BASEHARBOR_INSTALL_DIR/baha"
export BAHA

"$BAHA" target create "$BASEHARBOR_TARGET" --provider "$BASEHARBOR_TEST_RUNTIME" --access "local-$BASEHARBOR_TEST_RUNTIME" --reference local --scope default --default >/dev/null

cleanup() {
  set +e
  timeout 60s "$BAHA" destroy --all --yes >/dev/null 2>&1 || true
}
trap cleanup EXIT

cat >"$DEMO_ROOT/baseharbor.yaml" <<'EOF'
version: 1

app:
  name: debug-reconcile
  environment: dev

workload:
  compose: tests/debug-restore-route/compose.yaml
  services:
    - debug-app
EOF

source "$DEMO_ROOT/tests/lib.sh"

(
  cd "$DEMO_ROOT"
  "$BAHA" app init --tls local --yes >"$ARTIFACT_DIR/init.txt" 2>&1
  timeout 240s "$BAHA" --verbose up --yes >"$ARTIFACT_DIR/up.txt" 2>&1
  timeout 120s "$BAHA" app apply >"$ARTIFACT_DIR/noop.txt" 2>&1
)

target_slug="${BASEHARBOR_TARGET//./-}"
project="bh-${target_slug}-debug-reconcile-dev"
remove_managed_service_for_reconcile debug-app "$project"

(
  cd "$DEMO_ROOT"
  timeout 180s "$BAHA" app apply >"$ARTIFACT_DIR/recreate.txt" 2>&1
  timeout 120s "$BAHA" app doctor >"$ARTIFACT_DIR/doctor.txt" 2>&1
)
grep -q '^READY' "$ARTIFACT_DIR/doctor.txt"
printf 'PASS  Minimal reconciliation runtime repair\n'
