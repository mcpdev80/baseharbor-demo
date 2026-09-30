#!/usr/bin/env bash
set -euo pipefail

: "${BASEHARBOR_SOURCE_REF:?BASEHARBOR_SOURCE_REF is required}"
: "${BASEHARBOR_TEST_RUNTIME:?BASEHARBOR_TEST_RUNTIME is required}"
: "${ARTIFACT_DIR:?ARTIFACT_DIR is required}"

export BASEHARBOR_INSTALL_DIR="${BASEHARBOR_INSTALL_DIR:-$DEMO_ROOT/.tools/bin}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/tmp/baseharbor-debug-sql-restore/config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-/tmp/baseharbor-debug-sql-restore/data}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/baseharbor-debug-sql-restore/cache}"
export BASEHARBOR_TARGET="${BASEHARBOR_TARGET:-debug-sql-restore-${BASEHARBOR_TEST_RUNTIME}}"

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
cp "$DEMO_ROOT/compose.yaml" "$tmprepo/compose.yaml"
cp -R "$DEMO_ROOT/demo-app" "$tmprepo/demo-app"

(
  cd "$tmprepo"
  timeout 180s "$BAHA" up --yes --control-plane-only --recovery-file "$ARTIFACT_DIR/openbao-recovery.json" >"$ARTIFACT_DIR/control-plane.txt" 2>&1
  "$BAHA" app init demo --environment dev --sql --workload-compose compose.yaml --workload-service demo-app >"$ARTIFACT_DIR/init-app.txt" 2>&1
  "$BAHA" app init --tls local --yes >"$ARTIFACT_DIR/init-runtime.txt" 2>&1
  timeout 240s "$BAHA" --verbose up --yes >"$ARTIFACT_DIR/initial-up.txt" 2>&1
)

gateway_state="$XDG_DATA_HOME/baseharbor/targets/$BASEHARBOR_TARGET/developer-access/dev/gateway/routes.json"
gateway_ca="$XDG_DATA_HOME/baseharbor/targets/$BASEHARBOR_TARGET/developer-access/dev/gateway/runtime/ca.pem"
test -s "$gateway_state"
test -s "$gateway_ca"
gateway_port="$(jq -r '.host_port' "$gateway_state")"
base="https://demo.baha.localhost"
if [ "$gateway_port" != "443" ]; then base="$base:$gateway_port"; fi
curl_dev=(curl -sS --cacert "$gateway_ca" --resolve "demo.baha.localhost:$gateway_port:127.0.0.1")

seed_code="$("${curl_dev[@]}" -o "$ARTIFACT_DIR/sql-seed.json" -w '%{http_code}' -X POST "$base/api/sql" || true)"
printf '%s\n' "$seed_code" >"$ARTIFACT_DIR/sql-seed.code"
test "$seed_code" = "200"
jq -e '.records>=1' "$ARTIFACT_DIR/sql-seed.json" >/dev/null

printf '%s' 'debug-sql-restore-password' >"$ARTIFACT_DIR/backup.pass"
chmod 600 "$ARTIFACT_DIR/backup.pass"
(
  cd "$tmprepo"
  timeout 180s "$BAHA" app backup --include-state database.sql --password-file "$ARTIFACT_DIR/backup.pass" --output "$ARTIFACT_DIR/sql.bhbackup" >"$ARTIFACT_DIR/backup.txt" 2>&1
  timeout 180s "$BAHA" app destroy --yes >"$ARTIFACT_DIR/destroy.txt" 2>&1
  timeout 300s "$BAHA" app restore "$ARTIFACT_DIR/sql.bhbackup" --password-file "$ARTIFACT_DIR/backup.pass" >"$ARTIFACT_DIR/restore.txt" 2>&1
  "$BAHA" app doctor >"$ARTIFACT_DIR/doctor.txt" 2>&1
)
grep -q '^READY' "$ARTIFACT_DIR/doctor.txt"

health_code="$("${curl_dev[@]}" -o "$ARTIFACT_DIR/health-after.json" -w '%{http_code}' "$base/healthz" || true)"
printf '%s\n' "$health_code" >"$ARTIFACT_DIR/health-after.code"
if [ "$health_code" != "200" ]; then
  "$BASEHARBOR_TEST_RUNTIME" ps -a --format '{{.ID}} {{.Names}} {{.Status}}' >"$ARTIFACT_DIR/runtime-ps.txt" 2>&1 || true
  exit 1
fi

sql_code="$("${curl_dev[@]}" -o "$ARTIFACT_DIR/sql-after.json" -w '%{http_code}' -X POST "$base/api/sql" || true)"
printf '%s\n' "$sql_code" >"$ARTIFACT_DIR/sql-after.code"
if [ "$sql_code" != "200" ]; then
  "${curl_dev[@]}" -o "$ARTIFACT_DIR/status-after.json" "$base/api/status" || true
  "$BASEHARBOR_TEST_RUNTIME" ps -a --format '{{.ID}} {{.Names}} {{.Status}}' >"$ARTIFACT_DIR/runtime-ps.txt" 2>&1 || true
  echo "SQL restore write failed with HTTP $sql_code" >&2
  cat "$ARTIFACT_DIR/sql-after.json" >&2 || true
  exit 1
fi
jq -e '.records>=2' "$ARTIFACT_DIR/sql-after.json" >/dev/null
printf 'PASS  Minimal SQL backup/destroy/restore/write\n'
