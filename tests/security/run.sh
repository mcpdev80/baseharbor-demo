#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Workload security"
tmp="$(mktemp)"
cp "$DEMO_ROOT/compose.yaml" "$tmp"
trap 'cp "$tmp" "$DEMO_ROOT/compose.yaml"; rm -f "$tmp"' EXIT

python3 - "$DEMO_ROOT/compose.yaml" <<'PY'
from pathlib import Path
p = Path(__import__("sys").argv[1])
s = p.read_text()
s = s.replace("    restart: unless-stopped\n\n  postgres:", "    restart: unless-stopped\n    privileged: true\n\n  postgres:", 1)
p.write_text(s)
PY

set +e
(
  cd "$DEMO_ROOT"
  "$BAHA" app preflight
) >"$ARTIFACT_DIR/security-privileged.txt" 2>&1
rc=$?
set -e
test "$rc" -ne 0
pass "Workload Security" "privileged workload denied before mutation"

cp "$tmp" "$DEMO_ROOT/compose.yaml"
trap - EXIT
rm -f "$tmp"


section "TLS file binding boundary"

(
  cd "$DEMO_ROOT"
  "$BAHA" app exec demo-app /bin/sh -ec '
  require_env() {
    name="$1"
    value="$(printenv "$name" 2>/dev/null || true)"
    if [ -z "$value" ]; then echo "missing workload environment: $name" >&2; exit 31; fi
  }
  require_file() {
    path="$1"
    if [ ! -s "$path" ]; then echo "missing workload binding file: $path" >&2; exit 32; fi
  }
  require_env DATABASE_CA_FILE
  test -n "$DATABASE_CA_FILE"
  require_env REDIS_CA_FILE
  test -n "$REDIS_CA_FILE"
  require_env AWS_CA_BUNDLE
  test -n "$AWS_CA_BUNDLE"
  require_env OTEL_EXPORTER_OTLP_CERTIFICATE
  test -n "$OTEL_EXPORTER_OTLP_CERTIFICATE"
  require_env TLS_CERT_FILE
  test -n "$TLS_CERT_FILE"
  require_env TLS_KEY_FILE
  test -n "$TLS_KEY_FILE"
  require_env BASEHARBOR_RUNTIME_CA_FILE
  test -n "$BASEHARBOR_RUNTIME_CA_FILE"
  require_env BASEHARBOR_RUNTIME_CLIENT_CERT_FILE
  test -n "$BASEHARBOR_RUNTIME_CLIENT_CERT_FILE"
  require_env BASEHARBOR_RUNTIME_CLIENT_KEY_FILE
  test -n "$BASEHARBOR_RUNTIME_CLIENT_KEY_FILE"
  require_env OIDC_ISSUER
  test -n "$OIDC_ISSUER"
  require_env OIDC_CLIENT_ID
  test -n "$OIDC_CLIENT_ID"
  require_env OIDC_CA_FILE
  test -n "$OIDC_CA_FILE"

  require_file "$DATABASE_CA_FILE"
  test -s "$DATABASE_CA_FILE"
  require_file "$REDIS_CA_FILE"
  test -s "$REDIS_CA_FILE"
  require_file "$AWS_CA_BUNDLE"
  test -s "$AWS_CA_BUNDLE"
  require_file "$OTEL_EXPORTER_OTLP_CERTIFICATE"
  test -s "$OTEL_EXPORTER_OTLP_CERTIFICATE"
  require_file "$TLS_CERT_FILE"
  test -s "$TLS_CERT_FILE"
  require_file "$TLS_KEY_FILE"
  test -s "$TLS_KEY_FILE"
  require_file "$BASEHARBOR_RUNTIME_CA_FILE"
  test -s "$BASEHARBOR_RUNTIME_CA_FILE"
  require_file "$BASEHARBOR_RUNTIME_CLIENT_CERT_FILE"
  test -s "$BASEHARBOR_RUNTIME_CLIENT_CERT_FILE"
  require_file "$BASEHARBOR_RUNTIME_CLIENT_KEY_FILE"
  test -s "$BASEHARBOR_RUNTIME_CLIENT_KEY_FILE"
  require_file "$OIDC_CA_FILE"
  test -s "$OIDC_CA_FILE"

  case "$DATABASE_URL" in
    *baseharbor_admin*) echo "provider admin leaked through DATABASE_URL" >&2; exit 1 ;;
  esac
  test -s /run/baseharbor/service-bindings/postgres/username
  test "$(cat /run/baseharbor/service-bindings/postgres/username)" != "baseharbor_admin"
  ! grep -R -Fq "baseharbor_admin" /run/baseharbor/service-bindings
'
)

api_host="demo.baha.localhost"
gateway_ca="$XDG_DATA_HOME/baseharbor/targets/$BASEHARBOR_TARGET/developer-access/dev/gateway/runtime/ca.pem"
test -s "$gateway_ca"
gateway_port="$(dev_gateway_port)"
base="$(dev_gateway_url "$api_host")"
curl_dev=(curl -sS --cacert "$gateway_ca" --resolve "$api_host:$gateway_port:127.0.0.1")

security_api_post() {
  local name="$1"
  local path="$2"
  local jq_expr="$3"
  local body="$ARTIFACT_DIR/security-$name.json"
  local code
  code="$("${curl_dev[@]}" -o "$body" -w '%{http_code}' -X POST "$base$path")"
  if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
    echo "security API check $name failed with HTTP $code" >&2
    cat "$body" >&2 || true
    return 1
  fi
  jq -e "$jq_expr" "$body" >/dev/null
}

security_api_post sql /api/sql '.records>=1'
security_api_post cache /api/cache '.value=="portable-cache-value"'
security_api_post object /api/object '.bucket|length>0'
security_api_post trace /api/trace '.export_configured==true'

pass "TLS File Bindings" "environment exposes paths only; CA/cert/key material is mounted as files and consumed by the workload"

section "Canonical development gateway security"

(
  cd "$DEMO_ROOT"
  "$BAHA" status -o json > "$ARTIFACT_DIR/security-canonical-status.json"
)

jq -e '
  all(.management_ui[]?;
    (.url | startswith("https://")) and
    ((.url | test("127\\.0\\.0\\.1|localhost:[0-9]+")) | not)
  ) and
  any(.checks[]?; .name == "api" and .ok == true and (.detail | startswith("https://demo.baha.localhost")))
' "$ARTIFACT_DIR/security-canonical-status.json" >/dev/null

if grep -R -n -E 'tls_insecure_skip_verify|insecure_skip_verify'   "${XDG_DATA_HOME:-$HOME/.local/share}/baseharbor"   "$DEMO_ROOT/.baseharbor" 2>/dev/null; then
  echo "canonical development routing contains an insecure TLS bypass" >&2
  exit 1
fi

! grep -Fq 'baseharbor_admin' "$ARTIFACT_DIR/security-canonical-status.json"
assert_no_secret_leak "$ARTIFACT_DIR/security-canonical-status.json"
pass "Canonical Development Gateway" "canonical HTTPS routes are verified without insecure backend TLS bypass"
