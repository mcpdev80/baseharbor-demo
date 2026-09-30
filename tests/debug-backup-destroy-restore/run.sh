#!/usr/bin/env bash
set -euo pipefail

: "${BASEHARBOR_SOURCE_REF:?BASEHARBOR_SOURCE_REF is required}"
: "${BASEHARBOR_TEST_RUNTIME:?BASEHARBOR_TEST_RUNTIME is required}"
: "${ARTIFACT_DIR:?ARTIFACT_DIR is required}"
: "${DEMO_ROOT:?DEMO_ROOT is required}"

export BASEHARBOR_INSTALL_DIR="${BASEHARBOR_INSTALL_DIR:-$DEMO_ROOT/.tools/bin}"
export BASEHARBOR_RUNTIME_IMAGE="${BASEHARBOR_RUNTIME_IMAGE:-localhost/baseharbor-runtime:demo-candidate-${BASEHARBOR_SOURCE_REF}}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/tmp/baseharbor-debug-backup-destroy/config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-/tmp/baseharbor-debug-backup-destroy/data}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/baseharbor-debug-backup-destroy/cache}"
export BASEHARBOR_TARGET="${BASEHARBOR_TARGET:-debug-backup-destroy-${BASEHARBOR_TEST_RUNTIME}}"

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
  "$BAHA" app init demo --environment dev --sql --s3-bucket uploads --require-secret APP_SECRET --workload-compose compose.yaml --workload-service demo-app
  cat >> baseharbor.yaml <<'EOF'
runtime:
  permissions:
    - capability: object-storage.s3/v1
      services:
        - demo-app
      operations:
        - runtime.create
EOF
  "$BAHA" app init --tls local --yes
  set +e
  timeout 300s "$BAHA" --verbose up --yes >"$ARTIFACT_DIR/first-up.txt" 2>&1
  set -e
  printf '%s' 'acceptance-secret-value' | "$BAHA" app secret set APP_SECRET --stdin
  timeout 300s "$BAHA" --verbose app apply >"$ARTIFACT_DIR/apply.txt" 2>&1
  timeout 120s "$BAHA" app doctor >"$ARTIFACT_DIR/doctor-before.txt" 2>&1
)
grep -q '^READY' "$ARTIFACT_DIR/doctor-before.txt"

api_host="demo.baha.localhost"
gateway_port="$(dev_gateway_port)"
base="$(dev_gateway_url "$api_host")"
gateway_ca="$XDG_DATA_HOME/baseharbor/targets/$BASEHARBOR_TARGET/developer-access/dev/gateway/runtime/ca.pem"
test -s "$gateway_ca"
curl_dev=(curl -fsS --cacert "$gateway_ca" --resolve "$api_host:$gateway_port:127.0.0.1")

"${curl_dev[@]}" -X POST "$base/api/sql" >"$ARTIFACT_DIR/sql-seed.json"
"${curl_dev[@]}" -X POST "$base/api/object" >"$ARTIFACT_DIR/s3-seed.json"
"${curl_dev[@]}" -X POST --data-binary 'durable-workload-state-v0418' "$base/api/file" >"$ARTIFACT_DIR/file-seed.json"
"${curl_dev[@]}" -X POST "$base/api/secret" | jq -e '.present==true and .value_exposed==false' >/dev/null

printf '%s' 'acceptance-backup-password' >"$ARTIFACT_DIR/backup.pass"
chmod 600 "$ARTIFACT_DIR/backup.pass"

printf 'PHASE backup\n'
(
  cd "$DEMO_ROOT"
  timeout 240s "$BAHA" app backup --password-file "$ARTIFACT_DIR/backup.pass" --output "$ARTIFACT_DIR/demo.bhbackup" >"$ARTIFACT_DIR/backup.txt" 2>&1
)

printf 'PHASE destroy\n'
(
  cd "$DEMO_ROOT"
  timeout 180s "$BAHA" app destroy --yes >"$ARTIFACT_DIR/destroy.txt" 2>&1
)

printf 'PHASE restore\n'
(
  cd "$DEMO_ROOT"
  timeout 300s "$BAHA" app restore "$ARTIFACT_DIR/demo.bhbackup" --password-file "$ARTIFACT_DIR/backup.pass" >"$ARTIFACT_DIR/restore.txt" 2>&1
  timeout 120s "$BAHA" app doctor >"$ARTIFACT_DIR/restore-doctor.txt" 2>&1
  "$BAHA" app evidence -o json >"$ARTIFACT_DIR/recovery-evidence.json"
)
grep -q '^READY' "$ARTIFACT_DIR/restore-doctor.txt"

printf 'PHASE evidence\n'
jq -e '
  any(.recovery.contributors[]; .state_class=="database.sql" and .verified==true) and
  any(.recovery.contributors[]; .state_class=="secrets" and .verified==true) and
  any(.recovery.contributors[]; .state_class=="object-storage.s3" and .verified==true) and
  any(.recovery.contributors[]; .state_class=="workload.storage" and .verified==true) and
  any(.audit_events[]; .operation=="restore" and .outcome=="success")
' "$ARTIFACT_DIR/recovery-evidence.json" >/dev/null

code="$(curl -sS --cacert "$gateway_ca" --resolve "$api_host:$gateway_port:127.0.0.1" -o "$ARTIFACT_DIR/post-restore-health.json" -w '%{http_code}' "$base/healthz" || true)"
test "$code" = "200"
jq -e '.status=="ok"' "$ARTIFACT_DIR/post-restore-health.json" >/dev/null

printf 'PASS  Minimal backup destroy restore\n'
