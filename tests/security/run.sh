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
  test -n "$DATABASE_CA_FILE"
  test -n "$REDIS_CA_FILE"
  test -n "$AWS_CA_BUNDLE"
  test -n "$OTEL_EXPORTER_OTLP_CERTIFICATE"
  test -n "$TLS_CERT_FILE"
  test -n "$TLS_KEY_FILE"
  test -n "$BASEHARBOR_RUNTIME_CA_FILE"
  test -n "$BASEHARBOR_RUNTIME_CLIENT_CERT_FILE"
  test -n "$BASEHARBOR_RUNTIME_CLIENT_KEY_FILE"
  test -n "$OIDC_ISSUER"
  test -n "$OIDC_CLIENT_ID"
  test -n "$OIDC_CA_FILE"

  test -s "$DATABASE_CA_FILE"
  test -s "$REDIS_CA_FILE"
  test -s "$AWS_CA_BUNDLE"
  test -s "$OTEL_EXPORTER_OTLP_CERTIFICATE"
  test -s "$TLS_CERT_FILE"
  test -s "$TLS_KEY_FILE"
  test -s "$BASEHARBOR_RUNTIME_CA_FILE"
  test -s "$BASEHARBOR_RUNTIME_CLIENT_CERT_FILE"
  test -s "$BASEHARBOR_RUNTIME_CLIENT_KEY_FILE"
  test -s "$OIDC_CA_FILE"
'
)

api_host="baseharbor-demo-api.baseharbor.localhost"
gateway_ca="$XDG_DATA_HOME/baseharbor/targets/$BASEHARBOR_TARGET/developer-access/dev/gateway/runtime/ca.pem"
test -s "$gateway_ca"
base="https://$api_host"
curl_dev=(curl -fsS --cacert "$gateway_ca" --resolve "$api_host:443:127.0.0.1")
"${curl_dev[@]}" -X POST "$base/api/sql" | jq -e '.records>=1' >/dev/null
"${curl_dev[@]}" -X POST "$base/api/cache" | jq -e '.value=="portable-cache-value"' >/dev/null
"${curl_dev[@]}" -X POST "$base/api/object" | jq -e '.bucket|length>0' >/dev/null
"${curl_dev[@]}" -X POST "$base/api/trace" | jq -e '.export_configured==true' >/dev/null

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
  any(.checks[]?; .name == "api" and .ok == true and (.detail | startswith("https://baseharbor-demo-api.baseharbor.localhost")))
' "$ARTIFACT_DIR/security-canonical-status.json" >/dev/null

if grep -R -n -E 'tls_insecure_skip_verify|insecure_skip_verify'   "${XDG_DATA_HOME:-$HOME/.local/share}/baseharbor"   "$DEMO_ROOT/.baseharbor" 2>/dev/null; then
  echo "canonical development routing contains an insecure TLS bypass" >&2
  exit 1
fi

assert_no_secret_leak "$ARTIFACT_DIR/security-canonical-status.json"
pass "Canonical Development Gateway" "canonical HTTPS routes are verified without insecure backend TLS bypass"
