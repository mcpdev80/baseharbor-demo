#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Guided pristine-repository happy path"

clean_generated_state
rm -rf "$XDG_CONFIG_HOME/baseharbor" "$XDG_DATA_HOME/baseharbor" "$XDG_DATA_HOME/baseharbor-recovery"
"$BAHA" target create "$BASEHARBOR_TARGET"   --provider "$BASEHARBOR_TEST_RUNTIME"   --access "local-$BASEHARBOR_TEST_RUNTIME"   --reference local   --scope default   --default >/dev/null

test ! -e "$DEMO_ROOT/baseharbor.yaml"
test ! -e "$DEMO_ROOT/.baseharbor"

compose_before="$(sha256sum "$DEMO_ROOT/compose.yaml" | awk '{print $1}')"

echo "[phase] guided: initialize and converge application"
python3 "$DEMO_ROOT/tests/guided/drive.py"

test -s "$DEMO_ROOT/baseharbor.yaml"
compose_after="$(sha256sum "$DEMO_ROOT/compose.yaml" | awk '{print $1}')"
test "$compose_before" = "$compose_after"

grep -q '^workload:' "$DEMO_ROOT/baseharbor.yaml"
grep -q '^metrics:' "$DEMO_ROOT/baseharbor.yaml"
grep -q '^telemetry:' "$DEMO_ROOT/baseharbor.yaml"
grep -q '^logs:' "$DEMO_ROOT/baseharbor.yaml"
grep -q '^runtime:' "$DEMO_ROOT/baseharbor.yaml"
grep -q '^identity:' "$DEMO_ROOT/baseharbor.yaml"
grep -q 'management_ui' "$DEMO_ROOT/baseharbor.yaml"
grep -q 'APP_SECRET' "$DEMO_ROOT/baseharbor.yaml"
grep -q 'uploads' "$DEMO_ROOT/baseharbor.yaml"

(
  cd "$DEMO_ROOT"
  echo "[phase] guided status: collect application readiness"
  "$BAHA" status --verbose | tee "$ARTIFACT_DIR/guided-status.txt"
  echo "[phase] guided doctor: verify provider and workload health"
  "$BAHA" doctor | tee "$ARTIFACT_DIR/guided-doctor.txt"
)

grep -q '^READY' "$ARTIFACT_DIR/guided-doctor.txt"
dev_domain="$("$BAHA" dev domain | awk '$1 == "Domain" {print $2}')"
test "$dev_domain" = "baha.localhost"

dev_credentials="$(mktemp)"
chmod 600 "$dev_credentials"
"$BAHA" dev credentials >"$dev_credentials"
grep -Eq '^[[:space:]]*Username[[:space:]]+developer$' "$dev_credentials"
password="$(awk '$1 == "Password" {print $2}' "$dev_credentials")"
test -n "$password"
rm -f "$dev_credentials"
unset password

gateway_ca="$XDG_DATA_HOME/baseharbor/targets/$BASEHARBOR_TARGET/developer-access/dev/gateway/runtime/ca.pem"
test -s "$gateway_ca"

canonical_hosts=(
  demo.baha.localhost
  pgadmin.baha.localhost
  cache.baha.localhost
  storage.baha.localhost
  auth.baha.localhost
  auth-admin.baha.localhost
  secrets.baha.localhost
  metrics.baha.localhost
)

gateway_port="$(dev_gateway_port)"
for host in "${canonical_hosts[@]}"; do
  url="$(dev_gateway_url "$host")"
  grep -q "$url" "$ARTIFACT_DIR/guided-status.txt"
  code="$(curl -sS --cacert "$gateway_ca" --resolve "$host:$gateway_port:127.0.0.1" -o /dev/null -w '%{http_code}' "$url/")"
  test "$code" -ge 200
  test "$code" -lt 500
done

swagger_host="demo.baha.localhost"
swagger_url="$(dev_gateway_url "$swagger_host")/swagger/"
grep -q "$swagger_url" "$ARTIFACT_DIR/guided-status.txt"
swagger_code="$(curl -sS --cacert "$gateway_ca" --resolve "$swagger_host:$gateway_port:127.0.0.1" -o /dev/null -w '%{http_code}' "$swagger_url")"
test "$swagger_code" -ge 200
test "$swagger_code" -lt 400

grep -q 'postgres/default.*scope=shared owner=demo/dev' "$ARTIFACT_DIR/guided-status.txt"
grep -q 'valkey.*app-isolated cache resource' "$ARTIFACT_DIR/guided-status.txt"
grep -q 'cross-application access isolation verified' "$ARTIFACT_DIR/guided-status.txt"

if grep -Eq 'https://(127\.0\.0\.1|localhost):[0-9]+' "$ARTIFACT_DIR/guided-status.txt"; then
  echo "guided status exposed implementation-detail loopback URLs" >&2
  exit 1
fi

assert_no_secret_leak "$ARTIFACT_DIR/guided-init.txt"
assert_no_secret_leak "$ARTIFACT_DIR/guided-up.txt"
assert_no_secret_leak "$ARTIFACT_DIR/guided-status.txt"
assert_no_secret_leak "$ARTIFACT_DIR/guided-doctor.txt"

pass "Guided Adoption Happy Path" "pristine repository -> one dev domain/login -> canonical HTTPS routes -> READY"
