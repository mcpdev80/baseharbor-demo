#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Backup and restore"

printf '%s' 'acceptance-backup-password' > "$ARTIFACT_DIR/backup.pass"
chmod 600 "$ARTIFACT_DIR/backup.pass"

# Build one deterministic recovery contract that exercises SQL, secrets, S3,
# application-owned workload storage and application log history.
(
  cd "$DEMO_ROOT"
  "$BAHA" app destroy --yes
)
rm -rf "$DEMO_ROOT/.baseharbor" "$DEMO_ROOT/baseharbor.yaml" "$DEMO_ROOT/baseharbor.repository.yaml"

(
  cd "$DEMO_ROOT"
  "$BAHA" app init demo \
    --environment dev \
    --sql \
    --cache \
    --s3-bucket uploads \
    --require-secret APP_SECRET \
    --workload-source compose:compose.yaml \
    --workload-component demo-app

  # The demo workload uses the Runtime Resource API to create S3 resources.
  # Explicit recovery init must preserve that authorization just like guided
  # repository adoption; without it the workload also loses its runtime mTLS
  # identity and application TLS certificate projection.
  python3 - <<'PY'
from pathlib import Path
p = Path("baseharbor.yaml")
s = p.read_text()
needle = "    - name: APP_SECRET\n"
replacement = "    - name: APP_SECRET\n      generate:\n        type: random\n        length: 32\n"
if needle not in s:
    raise SystemExit("APP_SECRET requirement not found in generated manifest")
p.write_text(s.replace(needle, replacement, 1))
PY

  cat >> baseharbor.yaml <<'EOF'
runtime:
  permissions:
    - capability: object-storage.s3/v1
      services:
        - demo-app
      operations:
        - runtime.create
exposure:
  http:
    - name: demo-app
      service: demo-app
      port: 8080
      protocol: https
      visibility: public
logs:
  collect:
    - application
EOF

  "$BAHA" app init --tls local --yes

  "$BAHA" --verbose up --yes 2>&1 | tee "$ARTIFACT_DIR/recovery-apply.txt"
)

api_host="demo.baha.localhost"
python3 "$DEMO_ROOT/tests/native-default-topology.py" --output "$ARTIFACT_DIR/native-topology-before.json"
( cd "$DEMO_ROOT" && "$BAHA" up --yes )
python3 "$DEMO_ROOT/tests/native-default-topology.py" --output "$ARTIFACT_DIR/native-topology-repeated-up.json"
gateway_port="$(dev_gateway_port)"
base="$(dev_gateway_url "$api_host")"
gateway_ca="$XDG_DATA_HOME/baseharbor/targets/$BASEHARBOR_TARGET/developer-access/dev/gateway/runtime/ca.pem"
test -s "$gateway_ca"
curl_dev=(curl -fsS --cacert "$gateway_ca" --resolve "$api_host:$gateway_port:127.0.0.1")

"${curl_dev[@]}" -X POST "$base"/api/sql > "$ARTIFACT_DIR/recovery-sql-seed.json"

"${curl_dev[@]}" -X POST "$base"/api/object > "$ARTIFACT_DIR/recovery-s3-seed.json"
jq -r '.object' "$ARTIFACT_DIR/recovery-s3-seed.json" > "$ARTIFACT_DIR/recovery-s3-object.txt"

"${curl_dev[@]}" -X POST --data-binary 'durable-workload-state-v0417' "$base/api/file" \
  > "$ARTIFACT_DIR/recovery-volume-seed.json"

"${curl_dev[@]}" -X POST "$base"/api/secret \
  | jq -e '.present==true and .value_exposed==false' >/dev/null

curl -sS --cacert "$gateway_ca" --resolve "$api_host:$gateway_port:127.0.0.1" -o /dev/null "$base/recovery-marker-v0417" || true

(
  cd "$DEMO_ROOT"
  "$BAHA" app backup \
    --include-state observability.logs \
    --password-file "$ARTIFACT_DIR/backup.pass" \
    --output "$ARTIFACT_DIR/demo.bhbackup"

  test -s "$ARTIFACT_DIR/demo.bhbackup"

  "$BAHA" app destroy --yes

  "$BAHA" app restore "$ARTIFACT_DIR/demo.bhbackup" \
    --password-file "$ARTIFACT_DIR/backup.pass" \
    > "$ARTIFACT_DIR/restore.txt"

  "$BAHA" app doctor > "$ARTIFACT_DIR/restore-doctor.txt"
  "$BAHA" app evidence -o json > "$ARTIFACT_DIR/recovery-evidence-after-restore.json"

  loki_dir="$XDG_DATA_HOME/baseharbor/targets/$BASEHARBOR_TARGET/providers/loki/shared"
  loki_port="$(awk -F= '$1=="BASEHARBOR_LOKI_PORT" { print $2 }' "$loki_dir/runtime.env")"
  test -n "$loki_port"
  curl -fsS \
    --cacert "$loki_dir/service-access/pki/ca.pem" \
    --get "https://127.0.0.1:$loki_port/loki/api/v1/query_range" \
    --data-urlencode 'query={baseharbor_application="demo",baseharbor_environment="dev"} |= "recovery-marker-v0417"' \
    --data-urlencode 'limit=10' \
    > "$ARTIFACT_DIR/recovery-logs-after-restore.json"
)

grep -q '^READY' "$ARTIFACT_DIR/restore-doctor.txt"
python3 "$DEMO_ROOT/tests/native-default-topology.py" --output "$ARTIFACT_DIR/native-topology-after-restore.json"

post_restore_ready=false
for attempt in 1 2 3 4 5 6; do
  code="$(curl -sS --cacert "$gateway_ca" --resolve "$api_host:$gateway_port:127.0.0.1" -o "$ARTIFACT_DIR/post-restore-health-body.json" -w '%{http_code}' "$base/healthz" || true)"
  printf '%s\t%s\n' "$attempt" "$code" >> "$ARTIFACT_DIR/post-restore-health-attempts.tsv"
  if [ "$code" = "200" ] && jq -e '.status=="ok"' "$ARTIFACT_DIR/post-restore-health-body.json" >/dev/null 2>&1; then
    post_restore_ready=true
    break
  fi
  if [ "$attempt" = "1" ]; then
    cp "$XDG_DATA_HOME/baseharbor/targets/$BASEHARBOR_TARGET/developer-access/dev/gateway/routes.json" "$ARTIFACT_DIR/post-restore-routes.json" 2>/dev/null || true
    "$CONTAINER_CLI" ps -a --format '{{.ID}} {{.Names}} {{.Status}}' > "$ARTIFACT_DIR/post-restore-runtime-ps.txt" 2>&1 || true
    (cd "$DEMO_ROOT" && "$BAHA" status --verbose) > "$ARTIFACT_DIR/post-restore-status.txt" 2>&1 || true
    (cd "$DEMO_ROOT" && "$BAHA" app doctor) > "$ARTIFACT_DIR/post-restore-doctor-debug.txt" 2>&1 || true
  fi
  sleep 2
done
if [ "$post_restore_ready" != true ]; then
  echo "post-restore canonical workload route did not become ready" >&2
  cat "$ARTIFACT_DIR/post-restore-health-attempts.tsv" >&2 || true
  cat "$ARTIFACT_DIR/post-restore-health-body.json" >&2 || true
  exit 1
fi

"${curl_dev[@]}" -X POST "$base"/api/sql \
  | jq -e '.records>=2' >/dev/null

object_name="$(cat "$ARTIFACT_DIR/recovery-s3-object.txt")"
"${curl_dev[@]}" "$base/api/object?name=$object_name" \
  | jq -e '.content=="BaseHarbor portable object storage demo\n"' >/dev/null

"${curl_dev[@]}" "$base/api/file" \
  | jq -e '.content=="durable-workload-state-v0417"' >/dev/null

"${curl_dev[@]}" -X POST "$base"/api/secret \
  | jq -e '.present==true and .value_exposed==false' >/dev/null

jq -e '
  .status=="success" and
  any(.data.result[].values[][]; contains("recovery-marker-v0417"))
' "$ARTIFACT_DIR/recovery-logs-after-restore.json" >/dev/null

jq -e '
  any(.recovery.contributors[]; .state_class=="database.sql" and .verified==true) and
  any(.recovery.contributors[]; .state_class=="secrets" and .verified==true) and
  any(.recovery.contributors[]; .state_class=="object-storage.s3" and .verified==true) and
  any(.recovery.contributors[]; .state_class=="workload.storage" and .verified==true) and
  any(.recovery.contributors[]; .state_class=="observability.logs" and .verified==true) and
  any(.audit_events[]; .operation=="restore" and .outcome=="success") and
  any(.observed_state[]; .id=="status:postgres/isolation" and .status=="ready") and
  any(.verified_result[]; .id=="doctor:postgres shared isolation" and .status=="verified")
' "$ARTIFACT_DIR/recovery-evidence-after-restore.json" >/dev/null

assert_no_grep_match -Fq 'baseharbor_admin' "$ARTIFACT_DIR/recovery-evidence-after-restore.json"
assert_no_secret_leak "$ARTIFACT_DIR/recovery-evidence-after-restore.json"

pass "Backup / Restore" "SQL + secrets + S3 + workload storage + log history restored with verified evidence"
