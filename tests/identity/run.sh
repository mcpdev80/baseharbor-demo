#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Managed identity and provider management surfaces"

api_host="demo.baha.localhost"
identity_host="auth.baha.localhost"
identity_base="$(dev_gateway_url "$identity_host")"
gateway_ca="$XDG_DATA_HOME/baseharbor/targets/$BASEHARBOR_TARGET/developer-access/dev/gateway/runtime/ca.pem"
test -s "$gateway_ca"
gateway_port="$(dev_gateway_port)"
base="$(dev_gateway_url "$api_host")"
curl_dev=(curl -fsS --cacert "$gateway_ca" --resolve "$api_host:$gateway_port:127.0.0.1")

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
    require_env() {
      name="$1"
      value="$(printenv "$name" 2>/dev/null || true)"
      if [ -z "$value" ]; then
        echo "missing workload environment: $name" >&2
        exit 21
      fi
    }
    require_file() {
      path="$1"
      if [ ! -s "$path" ]; then
        echo "missing workload binding file: $path" >&2
        ls -la "$(dirname "$path")" >&2 2>/dev/null || true
        exit 22
      fi
    }

    require_env OIDC_ISSUER
    expected_issuer_prefix="'"$identity_base"'/realms/"
    case "$OIDC_ISSUER" in
      "$expected_issuer_prefix"*) ;;
      *) echo "unexpected canonical OIDC issuer: $OIDC_ISSUER" >&2; exit 23 ;;
    esac
    require_env OIDC_CLIENT_ID
    require_env OIDC_CA_FILE
    require_file "$OIDC_CA_FILE"
    require_env SERVICE_BINDING_ROOT
    require_file "$SERVICE_BINDING_ROOT/identity/oidc.issuer"
    require_file "$SERVICE_BINDING_ROOT/identity/oidc.client-id"
    require_file "$SERVICE_BINDING_ROOT/identity/ca.crt"
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

discovery_url="$identity_base/realms/bh-demo-dev/.well-known/openid-configuration"
curl -fsS --cacert "$gateway_ca" --resolve "$identity_host:$gateway_port:127.0.0.1" "$discovery_url" > "$ARTIFACT_DIR/identity-canonical-discovery.json"
jq -e --arg prefix "$identity_base/realms/" '.issuer | startswith($prefix)' "$ARTIFACT_DIR/identity-canonical-discovery.json" >/dev/null

assert_no_secret_leak "$ARTIFACT_DIR/identity-demo-status.json"
assert_no_secret_leak "$ARTIFACT_DIR/identity-verify.json"
assert_no_secret_leak "$ARTIFACT_DIR/identity-baha-status.json"

pass "Management UI Surfaces" "selected SQL/cache/S3/secrets/identity/Prometheus surfaces are classified and HTTPS-addressable"
