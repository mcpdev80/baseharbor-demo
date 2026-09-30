#!/usr/bin/env bash
set -euo pipefail

: "${BASEHARBOR_SOURCE_REF:?BASEHARBOR_SOURCE_REF is required}"
: "${BASEHARBOR_TEST_RUNTIME:?BASEHARBOR_TEST_RUNTIME is required}"
: "${ARTIFACT_DIR:?ARTIFACT_DIR is required}"
: "${DEMO_ROOT:?DEMO_ROOT is required}"

export BASEHARBOR_INSTALL_DIR="${BASEHARBOR_INSTALL_DIR:-$DEMO_ROOT/.tools/bin}"
export BASEHARBOR_RUNTIME_IMAGE="${BASEHARBOR_RUNTIME_IMAGE:-localhost/baseharbor-runtime:demo-candidate-${BASEHARBOR_SOURCE_REF}}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/tmp/baseharbor-debug-reconcile-sequence/config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-/tmp/baseharbor-debug-reconcile-sequence/data}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/baseharbor-debug-reconcile-sequence/cache}"
export BASEHARBOR_TARGET="${BASEHARBOR_TARGET:-debug-reconcile-sequence-${BASEHARBOR_TEST_RUNTIME}}"

rm -rf "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$ARTIFACT_DIR" "$DEMO_ROOT/.baseharbor" "$DEMO_ROOT/baseharbor.yaml"
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

source "$DEMO_ROOT/tests/lib.sh"

cat >"$DEMO_ROOT/baseharbor.yaml" <<'EOF'
version: 1

app:
  name: demo
  environment: dev

services:
  database:
    sql:
      placement: shared

workload:
  compose: compose.yaml
  services:
    - demo-app
EOF

(
  cd "$DEMO_ROOT"
  "$BAHA" app init --tls local --yes >"$ARTIFACT_DIR/init.txt" 2>&1
  timeout 300s "$BAHA" --verbose up --yes >"$ARTIFACT_DIR/first-up.txt" 2>&1
  timeout 120s "$BAHA" app doctor >"$ARTIFACT_DIR/initial-doctor.txt" 2>&1
)
grep -q '^READY' "$ARTIFACT_DIR/initial-doctor.txt"

printf 'PHASE lifecycle-down-up\n'
(
  cd "$DEMO_ROOT"
  timeout 120s "$BAHA" app down >"$ARTIFACT_DIR/down.txt" 2>&1
  timeout 240s "$BAHA" up >"$ARTIFACT_DIR/up-after-down.txt" 2>&1
  timeout 120s "$BAHA" app doctor >"$ARTIFACT_DIR/after-up-doctor.txt" 2>&1
)
grep -q '^READY' "$ARTIFACT_DIR/after-up-doctor.txt"

printf 'PHASE noop\n'
(cd "$DEMO_ROOT" && timeout 120s "$BAHA" app apply >"$ARTIFACT_DIR/noop.txt" 2>&1)

target_slug="${BASEHARBOR_TARGET//./-}"
project="bh-${target_slug}-demo-dev"
remove_managed_service_for_reconcile demo-app "$project"

printf 'PHASE missing-workload\n'
(
  cd "$DEMO_ROOT"
  timeout 180s "$BAHA" app apply >"$ARTIFACT_DIR/recreate.txt" 2>&1
  timeout 120s "$BAHA" app doctor >"$ARTIFACT_DIR/recreate-doctor.txt" 2>&1
)
grep -q '^READY' "$ARTIFACT_DIR/recreate-doctor.txt"

shared_project="bh-${target_slug}-shared"
printf 'PHASE postgres-degraded\n'
if [ "$BASEHARBOR_TEST_RUNTIME" = "podman" ]; then
  systemctl --user stop "${shared_project}-postgres.service"
else
  postgres="$(container_id_for_service shared-postgres-dev "$shared_project")"
  test -n "$postgres"
  "$CONTAINER_CLI" stop "$postgres" >/dev/null
fi

set +e
(cd "$DEMO_ROOT" && timeout 120s "$BAHA" app doctor >"$ARTIFACT_DIR/degraded-doctor.txt" 2>&1)
degraded_rc=$?
set -e
test "$degraded_rc" -ne 0

printf 'PHASE postgres-repair\n'
(
  cd "$DEMO_ROOT"
  timeout 240s "$BAHA" app apply >"$ARTIFACT_DIR/repair.txt" 2>&1
  timeout 120s "$BAHA" app doctor >"$ARTIFACT_DIR/repair-doctor.txt" 2>&1
)
grep -q '^READY' "$ARTIFACT_DIR/repair-doctor.txt"

printf 'PASS  Minimal reconciliation sequence\n'
