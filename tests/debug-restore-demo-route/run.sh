#!/usr/bin/env bash
set -euo pipefail

: "${BASEHARBOR_SOURCE_REF:?BASEHARBOR_SOURCE_REF is required}"
: "${BASEHARBOR_TEST_RUNTIME:?BASEHARBOR_TEST_RUNTIME is required}"
: "${ARTIFACT_DIR:?ARTIFACT_DIR is required}"
: "${DEMO_ROOT:?DEMO_ROOT is required}"

export BASEHARBOR_INSTALL_DIR="${BASEHARBOR_INSTALL_DIR:-$DEMO_ROOT/.tools/bin}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/tmp/baseharbor-debug-restore-demo/config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-/tmp/baseharbor-debug-restore-demo/data}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/baseharbor-debug-restore-demo/cache}"
export BASEHARBOR_TARGET="${BASEHARBOR_TARGET:-debug-restore-demo-${BASEHARBOR_TEST_RUNTIME}}"

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

source "$DEMO_ROOT/tests/lib.sh"

rm -rf "$DEMO_ROOT/.baseharbor" "$DEMO_ROOT/baseharbor.yaml"
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
EOF
  "$BAHA" app init --tls local --yes
  set +e
  timeout 300s "$BAHA" --verbose up --yes >"$ARTIFACT_DIR/first-up.txt" 2>&1
  set -e
  printf '%s' 'acceptance-secret-value' | "$BAHA" app secret set APP_SECRET --stdin
  timeout 300s "$BAHA" --verbose app apply >"$ARTIFACT_DIR/apply.txt" 2>&1
)

api_host="demo.baha.localhost"
gateway_port="$(dev_gateway_port)"
base="$(dev_gateway_url "$api_host")"
gateway_ca="$XDG_DATA_HOME/baseharbor/targets/$BASEHARBOR_TARGET/developer-access/dev/gateway/runtime/ca.pem"
test -s "$gateway_ca"

initial_code="$(curl -sS --cacert "$gateway_ca" --resolve "$api_host:$gateway_port:127.0.0.1" -o "$ARTIFACT_DIR/before-backup-health.json" -w '%{http_code}' "$base/healthz" || true)"
test "$initial_code" = "200"
jq -e '.status=="ok"' "$ARTIFACT_DIR/before-backup-health.json" >/dev/null

printf '%s' 'acceptance-backup-password' >"$ARTIFACT_DIR/backup.pass"
chmod 600 "$ARTIFACT_DIR/backup.pass"

(
  cd "$DEMO_ROOT"
  timeout 240s "$BAHA" app backup --password-file "$ARTIFACT_DIR/backup.pass" --output "$ARTIFACT_DIR/demo.bhbackup" >"$ARTIFACT_DIR/backup.txt" 2>&1
  timeout 180s "$BAHA" app destroy --yes >"$ARTIFACT_DIR/destroy.txt" 2>&1
  timeout 300s "$BAHA" app restore "$ARTIFACT_DIR/demo.bhbackup" --password-file "$ARTIFACT_DIR/backup.pass" >"$ARTIFACT_DIR/restore.txt" 2>&1
  timeout 120s "$BAHA" app doctor >"$ARTIFACT_DIR/restore-doctor.txt" 2>&1
)

grep -q '^READY' "$ARTIFACT_DIR/restore-doctor.txt"

post_restore_ready=false
for attempt in 1 2 3 4 5 6; do
  code="$(curl -sS --cacert "$gateway_ca" --resolve "$api_host:$gateway_port:127.0.0.1" -o "$ARTIFACT_DIR/post-restore-health.json" -w '%{http_code}' "$base/healthz" || true)"
  printf '%s\t%s\n' "$attempt" "$code" >>"$ARTIFACT_DIR/post-restore-attempts.tsv"
  if [ "$code" = "200" ] && jq -e '.status=="ok"' "$ARTIFACT_DIR/post-restore-health.json" >/dev/null 2>&1; then
    post_restore_ready=true
    break
  fi
  if [ "$attempt" = "1" ]; then
    cp "$XDG_DATA_HOME/baseharbor/targets/$BASEHARBOR_TARGET/developer-access/dev/gateway/routes.json" "$ARTIFACT_DIR/routes-after-restore.json" 2>/dev/null || true
    "$BASEHARBOR_TEST_RUNTIME" ps -a --format '{{.ID}} {{.Names}} {{.Status}}' >"$ARTIFACT_DIR/runtime-ps-after-restore.txt" 2>&1 || true
    (cd "$DEMO_ROOT" && "$BAHA" status --verbose) >"$ARTIFACT_DIR/status-after-restore.txt" 2>&1 || true
  fi
  sleep 2
done

if [ "$post_restore_ready" != true ]; then
  echo 'post-restore canonical demo route did not become ready' >&2
  cat "$ARTIFACT_DIR/post-restore-attempts.tsv" >&2 || true
  cat "$ARTIFACT_DIR/post-restore-health.json" >&2 || true
  exit 1
fi

printf 'PASS  Minimal real-demo restore route\n'
