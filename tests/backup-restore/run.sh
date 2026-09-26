#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Backup and restore"

printf '%s' 'acceptance-backup-password' > "$ARTIFACT_DIR/backup.pass"
chmod 600 "$ARTIFACT_DIR/backup.pass"

# Use application-scoped Loki so destroy removes the original history. A
# recovered marker can then only come from the encrypted recovery unit.
export BASEHARBOR_PROVIDER_LOKI_SCOPE=application

(
  cd "$DEMO_ROOT"
  "$BAHA" app destroy --yes
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
    --secrets \
    --require-secret APP_SECRET \
    --workload-compose compose.yaml \
    --workload-service demo-app

  cat >> baseharbor.yaml <<'YAML'

logs:
  collect:
    - application
YAML

  "$BAHA" app init --tls local --yes

  set +e
  "$BAHA" --verbose up --yes > "$ARTIFACT_DIR/recovery-first-up.txt" 2>&1
  set -e

  printf '%s' 'acceptance-secret-value' | "$BAHA" app secret set APP_SECRET --stdin
  "$BAHA" --verbose app apply > "$ARTIFACT_DIR/recovery-apply.txt" 2>&1
)

curl -fsS -X POST http://127.0.0.1:8080/api/sql > "$ARTIFACT_DIR/recovery-seed-sql.json"
jq -e '.records>=1' "$ARTIFACT_DIR/recovery-seed-sql.json" >/dev/null

curl -fsS -X POST http://127.0.0.1:8080/api/object > "$ARTIFACT_DIR/recovery-seed-s3.json"
jq -e '.objects>=1' "$ARTIFACT_DIR/recovery-seed-s3.json" >/dev/null

curl -fsS -X POST http://127.0.0.1:8080/api/file > "$ARTIFACT_DIR/recovery-seed-file.json"
jq -e '.records>=1' "$ARTIFACT_DIR/recovery-seed-file.json" >/dev/null

curl -fsS -X POST http://127.0.0.1:8080/api/secret > "$ARTIFACT_DIR/recovery-seed-secret.json"
jq -e '.present==true and .value_exposed==false' "$ARTIFACT_DIR/recovery-seed-secret.json" >/dev/null

curl -fsS -X POST http://127.0.0.1:8080/api/log-marker > "$ARTIFACT_DIR/recovery-log-marker.json"
jq -e '.marker=="recovery-before-backup"' "$ARTIFACT_DIR/recovery-log-marker.json" >/dev/null

for _ in $(seq 1 20); do
  (
    cd "$DEMO_ROOT"
    "$BAHA" app logs demo-app > "$ARTIFACT_DIR/recovery-logs-before.txt" 2>&1
  ) || true
  if grep -q 'recovery-before-backup' "$ARTIFACT_DIR/recovery-logs-before.txt"; then
    break
  fi
  sleep 1
done
grep -q 'recovery-before-backup' "$ARTIFACT_DIR/recovery-logs-before.txt"

demo_volume="$("$CONTAINER_CLI" volume ls --format '{{.Name}}' | grep -E '(^|[_-])demo-data$' | head -n1 || true)"
test -n "$demo_volume"

(
  cd "$DEMO_ROOT"
  "$BAHA" app backup \
    --include-state observability.logs \
    --password-file "$ARTIFACT_DIR/backup.pass" \
    --output "$ARTIFACT_DIR/demo.bhbackup"
  test -s "$ARTIFACT_DIR/demo.bhbackup"

  "$BAHA" app evidence -o json > "$ARTIFACT_DIR/recovery-backup-evidence.json"
)

for state_class in database.sql secrets object-storage.s3 workload.storage observability.logs; do
  jq -e --arg class "$state_class" '
    .recovery.contributors[]
    | select(.state_class==$class and .selected==true and .verified==true)
  ' "$ARTIFACT_DIR/recovery-backup-evidence.json" >/dev/null
done

(
  cd "$DEMO_ROOT"
  "$BAHA" app destroy --yes
)

# Application-owned Compose volumes are intentionally preserved by destroy.
# Remove the proven demo volume to simulate the actual loss side of DR.
"$CONTAINER_CLI" volume rm "$demo_volume" > "$ARTIFACT_DIR/recovery-volume-remove.txt"

(
  cd "$DEMO_ROOT"
  "$BAHA" app restore "$ARTIFACT_DIR/demo.bhbackup" \
    --password-file "$ARTIFACT_DIR/backup.pass" > "$ARTIFACT_DIR/restore.txt"
  "$BAHA" app doctor > "$ARTIFACT_DIR/restore-doctor.txt"
  "$BAHA" app evidence -o json > "$ARTIFACT_DIR/recovery-restore-evidence.json"
)

grep -q '^READY' "$ARTIFACT_DIR/restore-doctor.txt"

curl -fsS -X POST http://127.0.0.1:8080/api/sql | tee "$ARTIFACT_DIR/recovery-restored-sql.json" | jq -e '.records>=2' >/dev/null
curl -fsS -X POST http://127.0.0.1:8080/api/object | tee "$ARTIFACT_DIR/recovery-restored-s3.json" | jq -e '.objects>=2' >/dev/null
curl -fsS -X POST http://127.0.0.1:8080/api/file | tee "$ARTIFACT_DIR/recovery-restored-file.json" | jq -e '.records>=2' >/dev/null
curl -fsS -X POST http://127.0.0.1:8080/api/secret | tee "$ARTIFACT_DIR/recovery-restored-secret.json" | jq -e '.present==true and .value_exposed==false' >/dev/null

for _ in $(seq 1 20); do
  (
    cd "$DEMO_ROOT"
    "$BAHA" app logs demo-app > "$ARTIFACT_DIR/recovery-logs-restored.txt" 2>&1
  ) || true
  if grep -q 'recovery-before-backup' "$ARTIFACT_DIR/recovery-logs-restored.txt"; then
    break
  fi
  sleep 1
done
grep -q 'recovery-before-backup' "$ARTIFACT_DIR/recovery-logs-restored.txt"

for state_class in database.sql secrets object-storage.s3 workload.storage observability.logs; do
  jq -e --arg class "$state_class" '
    .recovery.contributors[]
    | select(.state_class==$class and .selected==true and .verified==true)
  ' "$ARTIFACT_DIR/recovery-restore-evidence.json" >/dev/null
done

pass "Backup / Restore" "SQL + secrets + S3 + workload volume + scoped log history survived disaster recovery"
