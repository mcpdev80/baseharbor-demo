#!/usr/bin/env bash
set -euo pipefail

: "${BASEHARBOR_SOURCE_REF:?BASEHARBOR_SOURCE_REF is required}"
: "${BASEHARBOR_TEST_RUNTIME:?BASEHARBOR_TEST_RUNTIME is required}"
: "${ARTIFACT_DIR:?ARTIFACT_DIR is required}"

export BASEHARBOR_INSTALL_DIR="${BASEHARBOR_INSTALL_DIR:-$DEMO_ROOT/.tools/bin}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/tmp/baseharbor-debug-reconcile/config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-/tmp/baseharbor-debug-reconcile/data}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/baseharbor-debug-reconcile/cache}"
export BASEHARBOR_TARGET="${BASEHARBOR_TARGET:-debug-reconcile-${BASEHARBOR_TEST_RUNTIME}}"

rm -rf "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR"

bash "$DEMO_ROOT/scripts/install-baseharbor.sh" >"$ARTIFACT_DIR/install.txt" 2>&1
BAHA="$BASEHARBOR_INSTALL_DIR/baha"

"$BAHA" target create "$BASEHARBOR_TARGET" --provider "$BASEHARBOR_TEST_RUNTIME" --access "local-$BASEHARBOR_TEST_RUNTIME" --reference local --scope default --default >/dev/null

cleanup() {
  set +e
  timeout 90s "$BAHA" destroy --all --yes >/dev/null 2>&1 || true
}
trap cleanup EXIT

tmprepo="$ARTIFACT_DIR/repo"
mkdir -p "$tmprepo"
cp "$DEMO_ROOT/tests/debug-restore-route/compose.yaml" "$tmprepo/compose.yaml"
cat >"$tmprepo/baseharbor.yaml" <<'EOF'
version: 1

app:
  name: demo
  environment: dev

workload:
  compose: compose.yaml
  services:
    - debug-app
EOF

(
  cd "$tmprepo"
  timeout 180s "$BAHA" up --yes --control-plane-only --recovery-file "$ARTIFACT_DIR/openbao-recovery.json" >"$ARTIFACT_DIR/control-plane.txt" 2>&1
  "$BAHA" app init --tls local --yes >"$ARTIFACT_DIR/init.txt" 2>&1
  timeout 180s "$BAHA" --verbose up --yes >"$ARTIFACT_DIR/initial-up.txt" 2>&1
)

export DEMO_ROOT="$tmprepo"
export BAHA
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

(
  cd "$tmprepo"
  "$BAHA" app apply >"$ARTIFACT_DIR/reconcile-insync.txt"
)

target="$("$BAHA" target -o json | jq -r '.target.name')"
target_slug="${target//./-}"
project="bh-${target_slug}-demo-dev"
remove_service_for_reconciliation debug-app "$project"

(
  cd "$tmprepo"
  timeout 180s "$BAHA" app apply >"$ARTIFACT_DIR/reconcile-missing.txt" 2>&1
  "$BAHA" app doctor >"$ARTIFACT_DIR/reconcile-doctor.txt" 2>&1
)
grep -q '^READY' "$ARTIFACT_DIR/reconcile-doctor.txt"
container="$(container_id_for_service debug-app "$project")"
test -n "$container"
printf 'PASS  Minimal reconciliation NOOP -> MISSING -> RECREATE\n'
