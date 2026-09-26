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
  "$BAHA" app destroy --yes || true
)
rm -rf "$DEMO_ROOT/.baseharbor" "$DEMO_ROOT/baseharbor.yaml"

(
  cd "$DEMO_ROOT"
  "$BAHA" app init baseharbor-demo \
    --environment dev \
    --sql \
    --cache \
    --s3 \
    --s3-bucket uploads \
    --require-secret APP_SECRET \
    --workload-compose compose.yaml \
    --workload-service demo-app

  cat >> baseharbor.yaml <<'EOF'
logs:
  collect:
    - application
EOF

  "$BAHA" app init --tls local --yes

  set +e
  "$BAHA" --verbose up --yes > "$ARTIFACT_DIR/recovery-first-up.txt" 2>&1
  set -e

  printf '%s' 'acceptance-secret-value' | "$BAHA" app secret set APP_SECRET --stdin
  "$BAHA" --verbose app apply > "$ARTIFACT_DIR/recovery-apply.txt" 2>&1
)

curl -fsS -X POST http://127.0.0.1:8080/api/sql > "$ARTIFACT_DIR/recovery-sql-seed.json"

curl -fsS -X POST http://127.0.0.1:8080/api/object > "$ARTIFACT_DIR/recovery-s3-seed.json"
jq -r '.object' "$ARTIFACT_DIR/recovery-s3-seed.json" > "$ARTIFACT_DIR/recovery-s3-object.txt"

printf '%s' 'durable-workload-state-v0416' \
  | curl -fsS -X POST --data-binary @- http://127.0.0.1:8080/api/file \
  > "$ARTIFACT_DIR/recovery-volume-seed.json"

curl -fsS -X POST http://127.0.0.1:8080/api/secret \
  | jq -e '.present==true and .value_exposed==false' >/dev/null

curl -sS -o /dev/null http://127.0.0.1:8080/recovery-marker-v0416 || true

(
  cd "$DEMO_ROOT"
  "$BAHA" app backup \
    --include-state observability.logs \
    --password-file "$ARTIFACT_DIR/backup.pass" \
    --output "$ARTIFACT_DIR/demo.bhbackup"

  test -s "$ARTIFACT_DIR/demo.bhbackup"

  "$BAHA" app evidence -o json > "$ARTIFACT_DIR/recovery-evidence-before-destroy.json"
  jq -e '
    .contract_version=="v1" and
    .schema_version=="v1" and
    any(.recovery.contributors[]; .state_class=="database.sql" and .selected==true) and
    any(.recovery.contributors[]; .state_class=="secrets" and .selected==true) and
    any(.recovery.contributors[]; .state_class=="object-storage.s3" and .selected==true) and
    any(.recovery.contributors[]; .state_class=="workload.storage" and .selected==true) and
    any(.recovery.contributors[]; .state_class=="observability.logs" and .selected==true)
  ' "$ARTIFACT_DIR/recovery-evidence-before-destroy.json" >/dev/null

  "$BAHA" app destroy --yes

  "$BAHA" app restore "$ARTIFACT_DIR/demo.bhbackup" \
    --password-file "$ARTIFACT_DIR/backup.pass" \
    > "$ARTIFACT_DIR/restore.txt"

  "$BAHA" app doctor > "$ARTIFACT_DIR/restore-doctor.txt"
  "$BAHA" app evidence -o json > "$ARTIFACT_DIR/recovery-evidence-after-restore.json"
  "$BAHA" app logs demo-app > "$ARTIFACT_DIR/recovery-logs-after-restore.txt"
)

grep -q '^READY' "$ARTIFACT_DIR/restore-doctor.txt"

curl -fsS -X POST http://127.0.0.1:8080/api/sql \
  | jq -e '.records>=2' >/dev/null

object_name="$(cat "$ARTIFACT_DIR/recovery-s3-object.txt")"
curl -fsS "http://127.0.0.1:8080/api/object?name=$object_name" \
  | jq -e '.content=="BaseHarbor portable object storage demo\n"' >/dev/null

curl -fsS http://127.0.0.1:8080/api/file \
  | jq -e '.content=="durable-workload-state-v0416"' >/dev/null

curl -fsS -X POST http://127.0.0.1:8080/api/secret \
  | jq -e '.present==true and .value_exposed==false' >/dev/null

grep -q 'recovery-marker-v0416' "$ARTIFACT_DIR/recovery-logs-after-restore.txt"

jq -e '
  any(.recovery.contributors[]; .state_class=="database.sql" and .verified==true) and
  any(.recovery.contributors[]; .state_class=="secrets" and .verified==true) and
  any(.recovery.contributors[]; .state_class=="object-storage.s3" and .verified==true) and
  any(.recovery.contributors[]; .state_class=="workload.storage" and .verified==true) and
  any(.recovery.contributors[]; .state_class=="observability.logs" and .verified==true) and
  any(.audit_events[]; .operation=="restore" and .outcome=="success")
' "$ARTIFACT_DIR/recovery-evidence-after-restore.json" >/dev/null

assert_no_secret_leak "$ARTIFACT_DIR/recovery-evidence-before-destroy.json"
assert_no_secret_leak "$ARTIFACT_DIR/recovery-evidence-after-restore.json"

pass "Backup / Restore" "SQL + secrets + S3 + workload storage + log history restored with verified evidence"
