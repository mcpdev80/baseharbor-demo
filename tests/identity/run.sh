#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Managed identity and provider management surfaces"

base="https://baseharbor-demo-api.baseharbor.localhost"

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

assert_no_secret_leak "$ARTIFACT_DIR/identity-demo-status.json"
assert_no_secret_leak "$ARTIFACT_DIR/identity-verify.json"
assert_no_secret_leak "$ARTIFACT_DIR/identity-baha-status.json"

pass "Management UI Surfaces" "selected SQL/cache/S3/secrets/identity/Prometheus surfaces are classified and HTTPS-addressable"
