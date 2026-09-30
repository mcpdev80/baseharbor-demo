#!/usr/bin/env bash
set -euo pipefail

: "${BASEHARBOR_SOURCE_REF:?BASEHARBOR_SOURCE_REF is required}"
: "${BASEHARBOR_TEST_RUNTIME:?BASEHARBOR_TEST_RUNTIME is required}"
: "${ARTIFACT_DIR:?ARTIFACT_DIR is required}"
: "${DEMO_ROOT:?DEMO_ROOT is required}"

export BASEHARBOR_INSTALL_DIR="${BASEHARBOR_INSTALL_DIR:-$DEMO_ROOT/.tools/bin}"
export BASEHARBOR_RUNTIME_IMAGE="${BASEHARBOR_RUNTIME_IMAGE:-localhost/baseharbor-runtime:demo-candidate-${BASEHARBOR_SOURCE_REF}}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/tmp/baseharbor-debug-minops/config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-/tmp/baseharbor-debug-minops/data}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/baseharbor-debug-minops/cache}"
export BASEHARBOR_TARGET="${BASEHARBOR_TARGET:-debug-minops-${BASEHARBOR_TEST_RUNTIME}}"
if [ "$BASEHARBOR_TEST_RUNTIME" = "podman" ]; then
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
fi

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

(
  cd "$DEMO_ROOT"
  "$BAHA" app init demo --environment dev --sql --cache --s3-bucket uploads --require-secret APP_SECRET --workload-compose compose.yaml --workload-service demo-app
  cat >> baseharbor.yaml <<'EOF'
runtime:
  permissions:
    - capability: object-storage.s3/v1
      services:
        - demo-app
      operations:
        - runtime.create
logs:
  collect:
    - application
EOF
  "$BAHA" app init --tls local --yes
  set +e
  timeout 300s "$BAHA" --verbose up --yes >"$ARTIFACT_DIR/first-up.txt" 2>&1
  set -e
  printf '%s' 'acceptance-secret-value' | "$BAHA" app secret set APP_SECRET --stdin
  timeout 300s "$BAHA" --verbose app apply >"$ARTIFACT_DIR/initial-apply.txt" 2>&1
  timeout 120s "$BAHA" app doctor >"$ARTIFACT_DIR/initial-doctor.txt" 2>&1
)
grep -q '^READY' "$ARTIFACT_DIR/initial-doctor.txt"

printf 'PHASE lifecycle-down-up\n'
(
  cd "$DEMO_ROOT"
  timeout 120s "$BAHA" app down >"$ARTIFACT_DIR/lifecycle-down.txt" 2>&1
  timeout 300s "$BAHA" up >"$ARTIFACT_DIR/lifecycle-up.txt" 2>&1
  timeout 120s "$BAHA" app doctor >"$ARTIFACT_DIR/lifecycle-doctor.txt" 2>&1
)
grep -q '^READY' "$ARTIFACT_DIR/lifecycle-doctor.txt"

printf 'PHASE lifecycle-idempotency\n'
(
  cd "$DEMO_ROOT"
  timeout 300s "$BAHA" up >"$ARTIFACT_DIR/lifecycle-idempotent.txt" 2>&1
)
grep -Eq 'already READY|No changes|READY' "$ARTIFACT_DIR/lifecycle-idempotent.txt"

printf 'PHASE reconciliation-noop\n'
(cd "$DEMO_ROOT" && timeout 120s "$BAHA" app apply >"$ARTIFACT_DIR/reconcile-noop.txt" 2>&1)

target_slug="${BASEHARBOR_TARGET//./-}"
project="bh-${target_slug}-demo-dev"
remove_managed_service_for_reconcile demo-app "$project"
printf 'PHASE reconciliation-missing\n'
(
  cd "$DEMO_ROOT"
  timeout 180s "$BAHA" app apply >"$ARTIFACT_DIR/reconcile-missing.txt" 2>&1
  timeout 120s "$BAHA" app doctor >"$ARTIFACT_DIR/reconcile-missing-doctor.txt" 2>&1
)
grep -q '^READY' "$ARTIFACT_DIR/reconcile-missing-doctor.txt"

shared_project="bh-${target_slug}-shared"
postgres="$(container_id_for_service shared-postgres-dev "$shared_project")"
test -n "$postgres"
"$CONTAINER_CLI" stop "$postgres" >/dev/null 2>&1 || true
if "$CONTAINER_CLI" ps -q --filter "id=$postgres" | grep -q .; then
  echo "shared PostgreSQL container is still running after stop: $postgres" >&2
  exit 1
fi
set +e
(cd "$DEMO_ROOT" && timeout 120s "$BAHA" app doctor >"$ARTIFACT_DIR/reconcile-degraded-before.txt" 2>&1)
degraded_rc=$?
set -e
test "$degraded_rc" -ne 0
printf 'PHASE reconciliation-repair\n'
(
  cd "$DEMO_ROOT"
  timeout 240s "$BAHA" app apply >"$ARTIFACT_DIR/reconcile-repair.txt" 2>&1
  timeout 120s "$BAHA" app doctor >"$ARTIFACT_DIR/reconcile-repair-doctor.txt" 2>&1
)
grep -q '^READY' "$ARTIFACT_DIR/reconcile-repair-doctor.txt"

api_host="demo.baha.localhost"
gateway_port="$(dev_gateway_port)"
base="$(dev_gateway_url "$api_host")"
gateway_ca="$XDG_DATA_HOME/baseharbor/targets/$BASEHARBOR_TARGET/developer-access/dev/gateway/runtime/ca.pem"
test -s "$gateway_ca"
curl_dev=(curl -fsS --cacert "$gateway_ca" --resolve "$api_host:$gateway_port:127.0.0.1")

printf 'PHASE backup-seed\n'
"${curl_dev[@]}" -X POST "$base/api/sql" >"$ARTIFACT_DIR/sql-seed.json"
"${curl_dev[@]}" -X POST "$base/api/object" >"$ARTIFACT_DIR/s3-seed.json"
jq -r '.object' "$ARTIFACT_DIR/s3-seed.json" >"$ARTIFACT_DIR/s3-object.txt"
"${curl_dev[@]}" -X POST --data-binary 'durable-workload-state-v0418' "$base/api/file" >"$ARTIFACT_DIR/file-seed.json"
"${curl_dev[@]}" -X POST "$base/api/secret" | jq -e '.present==true and .value_exposed==false' >/dev/null
curl -sS --cacert "$gateway_ca" --resolve "$api_host:$gateway_port:127.0.0.1" -o /dev/null "$base/recovery-marker-v0418" || true

printf '%s' 'acceptance-backup-password' >"$ARTIFACT_DIR/backup.pass"
chmod 600 "$ARTIFACT_DIR/backup.pass"

printf 'PHASE backup-restore\n'
(
  cd "$DEMO_ROOT"
  timeout 240s "$BAHA" app backup --include-state observability.logs --password-file "$ARTIFACT_DIR/backup.pass" --output "$ARTIFACT_DIR/demo.bhbackup" >"$ARTIFACT_DIR/backup.txt" 2>&1
  timeout 180s "$BAHA" app destroy --yes >"$ARTIFACT_DIR/destroy.txt" 2>&1
  timeout 300s "$BAHA" app restore "$ARTIFACT_DIR/demo.bhbackup" --password-file "$ARTIFACT_DIR/backup.pass" >"$ARTIFACT_DIR/restore.txt" 2>&1
  timeout 120s "$BAHA" app doctor >"$ARTIFACT_DIR/restore-doctor.txt" 2>&1
  "$BAHA" app evidence -o json >"$ARTIFACT_DIR/recovery-evidence.json"
)
grep -q '^READY' "$ARTIFACT_DIR/restore-doctor.txt"

printf 'PHASE post-restore-health\n'
post_restore_ready=false
for attempt in 1 2 3 4 5 6; do
  code="$(curl -sS --cacert "$gateway_ca" --resolve "$api_host:$gateway_port:127.0.0.1" -o "$ARTIFACT_DIR/post-restore-health.json" -w '%{http_code}' "$base/healthz" || true)"
  printf '%s\t%s\n' "$attempt" "$code" >>"$ARTIFACT_DIR/post-restore-health-attempts.tsv"
  if [ "$code" = "200" ] && jq -e '.status=="ok"' "$ARTIFACT_DIR/post-restore-health.json" >/dev/null 2>&1; then
    post_restore_ready=true
    break
  fi
  if [ "$attempt" = "1" ]; then
    cp "$XDG_DATA_HOME/baseharbor/targets/$BASEHARBOR_TARGET/developer-access/dev/gateway/routes.json" "$ARTIFACT_DIR/routes-after-restore.json" 2>/dev/null || true
    "$BASEHARBOR_TEST_RUNTIME" ps -a --format '{{.ID}} {{.Names}} {{.Status}} {{.Image}}' >"$ARTIFACT_DIR/runtime-ps-after-restore.txt" 2>&1 || true
    (cd "$DEMO_ROOT" && "$BAHA" status --verbose) >"$ARTIFACT_DIR/status-after-restore.txt" 2>&1 || true
  fi
  sleep 2
done

if [ "$post_restore_ready" != true ]; then
  echo 'post-restore canonical route failed' >&2
  cat "$ARTIFACT_DIR/post-restore-health-attempts.tsv" >&2 || true
  exit 1
fi

printf 'PHASE recovery-evidence\n'
jq -e '
  any(.recovery.contributors[]; .state_class=="database.sql" and .verified==true) and
  any(.recovery.contributors[]; .state_class=="secrets" and .verified==true) and
  any(.recovery.contributors[]; .state_class=="object-storage.s3" and .verified==true) and
  any(.recovery.contributors[]; .state_class=="workload.storage" and .verified==true) and
  any(.recovery.contributors[]; .state_class=="observability.logs" and .verified==true) and
  any(.audit_events[]; .operation=="restore" and .outcome=="success")
' "$ARTIFACT_DIR/recovery-evidence.json" >/dev/null

printf 'PASS  Minimal operations sequence\n'
