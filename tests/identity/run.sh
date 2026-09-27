#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Managed identity and provider management surfaces"

api_host="baseharbor-demo-api.baseharbor.localhost"
identity_host="baseharbor-demo-identity.baseharbor.localhost"
gateway_ca="$XDG_DATA_HOME/baseharbor/targets/$BASEHARBOR_TARGET/developer-access/dev/gateway/runtime/ca.pem"
test -s "$gateway_ca"
base="https://$api_host"
curl_dev=(curl -fsS --cacert "$gateway_ca" --resolve "$api_host:443:127.0.0.1")

"${curl_dev[@]}" "$base/api/status" > "$ARTIFACT_DIR/identity-demo-status.json"
jq -e '.capabilities.identity.ready == true' "$ARTIFACT_DIR/identity-demo-status.json" >/dev/null
pass "Managed Identity" "application consumed standard OIDC discovery and client bindings"

"${curl_dev[@]}" -X POST "$base/api/identity/verify" > "$ARTIFACT_DIR/identity-verify.json"
jq -e '
  .discovery_verified == true and
  .client_id_present == true and
  .client_secret_file_present == true and
  .trust_file_present == true
' "$ARTIFACT_DIR/identity-verify.json" >/dev/null
pass "OIDC Discovery" "issuer, client, confidential credential file and managed trust bundle verified"

(
  cd "$DEMO_ROOT"
  "$BAHA" app exec demo-app /bin/sh -ec '
    test -n "$OIDC_ISSUER"
    case "$OIDC_ISSUER" in
      https://baseharbor-demo-identity.baseharbor.localhost/realms/*) ;;
      *) echo "unexpected canonical OIDC issuer: $OIDC_ISSUER" >&2; exit 1 ;;
    esac
    test -n "$OIDC_CLIENT_ID"
    test -n "$OIDC_CA_FILE"
    test -s "$OIDC_CA_FILE"
    test -n "$SERVICE_BINDING_ROOT"
    test -s "$SERVICE_BINDING_ROOT/identity/oidc.issuer"
    test -s "$SERVICE_BINDING_ROOT/identity/oidc.client-id"
    test -s "$SERVICE_BINDING_ROOT/identity/ca.crt"
  '
  "$BAHA" status -o json > "$ARTIFACT_DIR/identity-baha-status.json"
)

jq -e '.checks[] | select(.name == "identity/oidc" and .ok == true)' "$ARTIFACT_DIR/identity-baha-status.json" >/dev/null

for surface in sql cache object-storage secrets identity-login identity-admin observability; do
  jq -e --arg surface "$surface" '
    any(.management_ui[]?; .service == $surface and (.url | startswith("https://")))
  ' "$ARTIFACT_DIR/identity-baha-status.json" >/dev/null
done

jq -e '
  all(.management_ui[]?;
    (.url | startswith("https://")) and
    ((.url | test("127\\.0\\.0\\.1|localhost:[0-9]+")) | not)
  )
' "$ARTIFACT_DIR/identity-baha-status.json" >/dev/null

jq -e 'any(.management_ui[]?; .service == "identity-login" and .purpose == "user-facing")' "$ARTIFACT_DIR/identity-baha-status.json" >/dev/null
jq -e 'any(.management_ui[]?; .service == "identity-admin" and .purpose == "administration")' "$ARTIFACT_DIR/identity-baha-status.json" >/dev/null
jq -e 'any(.management_ui[]?; .service == "observability" and .purpose == "observability")' "$ARTIFACT_DIR/identity-baha-status.json" >/dev/null
jq -e '.checks[] | select(.name == "canonical-development-urls" and .ok == true)' "$ARTIFACT_DIR/identity-baha-status.json" >/dev/null

discovery_url="https://$identity_host/realms/bh-baseharbor-demo-dev/.well-known/openid-configuration"
curl -fsS --cacert "$gateway_ca" --resolve "$identity_host:443:127.0.0.1" "$discovery_url" > "$ARTIFACT_DIR/identity-canonical-discovery.json"
jq -e --arg prefix "https://$identity_host/realms/" '.issuer | startswith($prefix)' "$ARTIFACT_DIR/identity-canonical-discovery.json" >/dev/null
if jq -e '.issuer | test(":[0-9]+")' "$ARTIFACT_DIR/identity-canonical-discovery.json" >/dev/null; then
  echo "OIDC issuer exposed an implementation-detail port" >&2
  exit 1
fi

assert_no_secret_leak "$ARTIFACT_DIR/identity-demo-status.json"
assert_no_secret_leak "$ARTIFACT_DIR/identity-verify.json"
assert_no_secret_leak "$ARTIFACT_DIR/identity-baha-status.json"

pass "Management UI Surfaces" "selected SQL/cache/S3/secrets/identity/Prometheus surfaces are classified and HTTPS-addressable"
