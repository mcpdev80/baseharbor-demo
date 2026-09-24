#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Backup and restore"

printf '%s' 'acceptance-backup-password' > "$ARTIFACT_DIR/backup.pass"
chmod 600 "$ARTIFACT_DIR/backup.pass"

# v0.4.14 intentionally fails closed when managed object storage is part of the recovery unit.
set +e
(
  cd "$DEMO_ROOT"
  "$BAHA" app backup --password-file "$ARTIFACT_DIR/backup.pass" --output "$ARTIFACT_DIR/with-s3.bhbackup"
) > "$ARTIFACT_DIR/backup-with-s3.txt" 2>&1
s3_backup_rc=$?
set -e
test "$s3_backup_rc" -ne 0
pass "Backup Object-Storage Safety" "unsupported recovery unit failed closed"

# Rebuild the same ordinary workload with a backup-safe contract for a real DR cycle.
(
  cd "$DEMO_ROOT"
  "$BAHA" app destroy --yes
)
rm -rf "$DEMO_ROOT/.baseharbor" "$DEMO_ROOT/baseharbor.yaml"

(
  cd "$DEMO_ROOT"
  "$BAHA" app init baseharbor-demo     --environment dev     --sql     --cache     --require-secret APP_SECRET
  "$BAHA" app init --tls local --yes

  set +e
  "$BAHA" --verbose up --yes > "$ARTIFACT_DIR/backup-safe-first-up.txt" 2>&1
  set -e

  printf '%s' 'acceptance-secret-value' | "$BAHA" app secret set APP_SECRET --stdin
  "$BAHA" --verbose app apply > "$ARTIFACT_DIR/backup-safe-apply.txt" 2>&1
)

curl -fsS -X POST http://127.0.0.1:8080/api/sql > "$ARTIFACT_DIR/backup-seed.json"

(
  cd "$DEMO_ROOT"
  "$BAHA" app backup --password-file "$ARTIFACT_DIR/backup.pass" --output "$ARTIFACT_DIR/demo.bhbackup"
  test -s "$ARTIFACT_DIR/demo.bhbackup"
  "$BAHA" app destroy --yes
  "$BAHA" app restore "$ARTIFACT_DIR/demo.bhbackup" --password-file "$ARTIFACT_DIR/backup.pass" > "$ARTIFACT_DIR/restore.txt"
  "$BAHA" app doctor > "$ARTIFACT_DIR/restore-doctor.txt"
)
grep -q '^READY' "$ARTIFACT_DIR/restore-doctor.txt"
curl -fsS -X POST http://127.0.0.1:8080/api/sql | jq -e '.records>=2' >/dev/null
pass "Backup / Restore" "real persistent SQL state survived disaster recovery"
