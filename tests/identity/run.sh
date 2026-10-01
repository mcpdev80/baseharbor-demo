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
  if ! "$BAHA" app exec demo-app /bin/sh -ec '
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
  ' >"$ARTIFACT_DIR/identity-workload-binding.txt" 2>"$ARTIFACT_DIR/identity-workload-binding.stderr.txt"; then
    echo "identity workload binding verification failed" >&2
    cat "$ARTIFACT_DIR/identity-workload-binding.stderr.txt" >&2 || true
    exit 41
  fi

  if ! "$BAHA" status -o json > "$ARTIFACT_DIR/identity-baha-status.json" 2>"$ARTIFACT_DIR/identity-baha-status.stderr.txt"; then
    echo "identity BaseHarbor status command returned non-zero" >&2
    cat "$ARTIFACT_DIR/identity-baha-status.stderr.txt" >&2 || true
    exit 42
  fi
)

jq -e '.checks[] | select(.name == "identity/oidc" and .ok == true)' "$ARTIFACT_DIR/identity-baha-status.json" >/dev/null || {
  echo "identity status is missing READY identity/oidc check" >&2
  exit 43
}

if [ "${DEMO_ATOMIC_GATE:-0}" = "1" ]; then
  expected_surfaces=(identity-login identity-admin)
else
  expected_surfaces=(sql cache object-storage secrets identity-login identity-admin observability)
fi
for surface in "${expected_surfaces[@]}"; do
  jq -e --arg surface "$surface" '
    any(.management_ui[]?; .service == $surface and (.url | startswith("https://")))
  ' "$ARTIFACT_DIR/identity-baha-status.json" >/dev/null || {
    echo "identity status is missing canonical HTTPS management UI: $surface" >&2
    exit 44
  }
done

jq -e '
  all(.management_ui[]?;
    (.url | startswith("https://")) and
    ((.url | test("^https://(127\\.0\\.0\\.1|localhost)(:[0-9]+)?(/|$)")) | not)
  )
' "$ARTIFACT_DIR/identity-baha-status.json" >/dev/null || {
  echo "identity status contains a non-canonical management UI URL" >&2
  exit 45
}

jq -e 'any(.management_ui[]?; .service == "identity-login" and .purpose == "user-facing")' "$ARTIFACT_DIR/identity-baha-status.json" >/dev/null || { echo "identity-login purpose mismatch" >&2; exit 46; }
jq -e 'any(.management_ui[]?; .service == "identity-admin" and .purpose == "administration")' "$ARTIFACT_DIR/identity-baha-status.json" >/dev/null || { echo "identity-admin purpose mismatch" >&2; exit 47; }
if [ "${DEMO_ATOMIC_GATE:-0}" != "1" ]; then
  jq -e 'any(.management_ui[]?; .service == "observability" and .purpose == "observability")' "$ARTIFACT_DIR/identity-baha-status.json" >/dev/null || { echo "observability purpose mismatch" >&2; exit 48; }
fi
jq -e '.checks[] | select(.name == "canonical-development-urls" and .ok == true)' "$ARTIFACT_DIR/identity-baha-status.json" >/dev/null || { echo "canonical-development-urls is not READY" >&2; exit 49; }

discovery_url="$identity_base/realms/bh-demo-dev/.well-known/openid-configuration"
if ! curl -fsS --cacert "$gateway_ca" --resolve "$identity_host:$gateway_port:127.0.0.1" "$discovery_url"   > "$ARTIFACT_DIR/identity-canonical-discovery.json" 2>"$ARTIFACT_DIR/identity-canonical-discovery.stderr.txt"; then
  echo "canonical OIDC discovery through development gateway failed: $discovery_url" >&2
  cat "$ARTIFACT_DIR/identity-canonical-discovery.stderr.txt" >&2 || true
  exit 50
fi
jq -e --arg prefix "$identity_base/realms/" '.issuer | startswith($prefix)' "$ARTIFACT_DIR/identity-canonical-discovery.json" >/dev/null || {
  echo "canonical OIDC discovery issuer does not match $identity_base" >&2
  exit 51
}

assert_no_secret_leak "$ARTIFACT_DIR/identity-demo-status.json" || { echo "secret leak detected in identity-demo-status.json" >&2; exit 52; }
assert_no_secret_leak "$ARTIFACT_DIR/identity-verify.json" || { echo "secret leak detected in identity-verify.json" >&2; exit 53; }
assert_no_secret_leak "$ARTIFACT_DIR/identity-baha-status.json" || { echo "secret leak detected in identity-baha-status.json" >&2; exit 54; }

pass "Management UI Surfaces" "selected SQL/cache/S3/secrets/identity/Prometheus surfaces are classified and HTTPS-addressable"
