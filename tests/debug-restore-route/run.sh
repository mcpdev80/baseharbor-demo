#!/usr/bin/env bash
set -euo pipefail

: "${BASEHARBOR_SOURCE_REF:?BASEHARBOR_SOURCE_REF is required}"
: "${BASEHARBOR_TEST_RUNTIME:?BASEHARBOR_TEST_RUNTIME is required}"
: "${ARTIFACT_DIR:?ARTIFACT_DIR is required}"

export BASEHARBOR_INSTALL_DIR="${BASEHARBOR_INSTALL_DIR:-$DEMO_ROOT/.tools/bin}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/tmp/baseharbor-debug-restore/config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-/tmp/baseharbor-debug-restore/data}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/baseharbor-debug-restore/cache}"
export BASEHARBOR_TARGET="${BASEHARBOR_TARGET:-debug-restore-${BASEHARBOR_TEST_RUNTIME}}"

rm -rf "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR"

bash "$DEMO_ROOT/scripts/install-baseharbor.sh" >"$ARTIFACT_DIR/install.txt" 2>&1
BAHA="$BASEHARBOR_INSTALL_DIR/baha"

"$BAHA" target create "$BASEHARBOR_TARGET" --provider "$BASEHARBOR_TEST_RUNTIME" --access "local-$BASEHARBOR_TEST_RUNTIME" --reference local --scope default --default >/dev/null

cleanup() {
  set +e
  timeout 45s "$BAHA" destroy --all --yes >/dev/null 2>&1 || true
}
trap cleanup EXIT

rm -rf "$DEMO_ROOT/.baseharbor" "$DEMO_ROOT/baseharbor.yaml"
(
  cd "$DEMO_ROOT"
  "$BAHA" app init demo --environment dev --workload-compose tests/debug-restore-route/compose.yaml --workload-service debug-app
  "$BAHA" app init --tls local --yes
  timeout 180s "$BAHA" --verbose up --yes >"$ARTIFACT_DIR/up.txt" 2>&1
)

gateway_ca="$XDG_DATA_HOME/baseharbor/targets/$BASEHARBOR_TARGET/developer-access/dev/gateway/runtime/ca.pem"
routes="$XDG_DATA_HOME/baseharbor/targets/$BASEHARBOR_TARGET/developer-access/dev/gateway/routes.json"
test -s "$gateway_ca"
test -s "$routes"
gateway_port="$(jq -r '.host_port' "$routes")"
base="https://demo.baha.localhost${gateway_port:+:$gateway_port}"
if [ "$gateway_port" = "443" ]; then base="https://demo.baha.localhost"; fi
curl_dev=(curl -fsS --cacert "$gateway_ca" --resolve "demo.baha.localhost:$gateway_port:127.0.0.1")
"${curl_dev[@]}" "$base/healthz" | jq -e '.status=="ok"' >/dev/null

printf '%s' 'debug-restore-password' >"$ARTIFACT_DIR/backup.pass"
chmod 600 "$ARTIFACT_DIR/backup.pass"
(
  cd "$DEMO_ROOT"
  timeout 180s "$BAHA" app backup --password-file "$ARTIFACT_DIR/backup.pass" --output "$ARTIFACT_DIR/debug.bhbackup" >"$ARTIFACT_DIR/backup.txt" 2>&1
  timeout 120s "$BAHA" app destroy --yes >"$ARTIFACT_DIR/destroy.txt" 2>&1
  timeout 240s "$BAHA" app restore "$ARTIFACT_DIR/debug.bhbackup" --password-file "$ARTIFACT_DIR/backup.pass" >"$ARTIFACT_DIR/restore.txt" 2>&1
)

podman ps --format '{{.ID}} {{.Names}} {{.Status}}' >"$ARTIFACT_DIR/podman-ps.txt" 2>&1 || true
cp "$routes" "$ARTIFACT_DIR/routes-after-restore.json" 2>/dev/null || true

for attempt in 1 2 3 4 5; do
  code="$(curl -sS --cacert "$gateway_ca" --resolve "demo.baha.localhost:$gateway_port:127.0.0.1" -o "$ARTIFACT_DIR/health-body.json" -w '%{http_code}' "$base/healthz" || true)"
  printf '%s\t%s\n' "$attempt" "$code" >>"$ARTIFACT_DIR/health-attempts.tsv"
  if [ "$code" = "200" ] && jq -e '.status=="ok"' "$ARTIFACT_DIR/health-body.json" >/dev/null 2>&1; then
    printf 'PASS  Minimal restore route health\n'
    exit 0
  fi
  sleep 1
done

echo 'minimal restore route did not recover' >&2
exit 1
