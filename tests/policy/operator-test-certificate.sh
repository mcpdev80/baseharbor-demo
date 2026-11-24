#!/usr/bin/env bash
# Provision a disposable Keycloak issuer and authenticate the policy test
# operator with a CA-signed client certificate over OIDC Authorization Code +
# PKCE. This fixture is called only from the CI-marked policy gate.
set -euo pipefail

operator_test_idp_setup() {
  command -v docker >/dev/null && command -v openssl >/dev/null && command -v curl >/dev/null || {
    echo "CI test-certificate login requires Docker, OpenSSL, and curl." >&2
    return 2
  }
  local suffix port callback_port name image dir password token base realm_url execution auth_url login_pid user_id
  suffix="${BASHPID:-$$}"
  port=$((24000 + (suffix % 12000)))
  callback_port=$((36000 + (suffix % 20000)))
  name="bh-operator-test-idp-${suffix}"
  image="quay.io/keycloak/keycloak:26.8.0@sha256:b0f60d489d51c5d113390bdf5461d4c06e6051be026c05549f2e1e10ec352bcc"
  dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/baseharbor-operator-idp.XXXXXX")"
  password="test-only-${suffix}-$(openssl rand -hex 12)"
  realm_url="https://localhost:${port}/realms/demo-operator-test"
  base="https://localhost:${port}/admin/realms"
  OPERATOR_TEST_IDP_DIR="${dir}"
  OPERATOR_TEST_IDP_NAME="${name}"
  export OPERATOR_TEST_IDP_DIR OPERATOR_TEST_IDP_NAME
  chmod 0700 "$dir"

  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$dir/ca.key" -out "$dir/ca.pem" -days 1 -subj '/CN=BaseHarbor ephemeral operator-test CA' >/dev/null 2>&1
  openssl req -newkey rsa:2048 -nodes -keyout "$dir/server.key" -out "$dir/server.csr" -subj '/CN=localhost' >/dev/null 2>&1
  printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n' >"$dir/server.ext"
  openssl x509 -req -in "$dir/server.csr" -CA "$dir/ca.pem" -CAkey "$dir/ca.key" -CAcreateserial -out "$dir/server.pem" -days 1 -extfile "$dir/server.ext" >/dev/null 2>&1
  openssl req -newkey rsa:2048 -nodes -keyout "$dir/operator.key" -out "$dir/operator.csr" -subj '/CN=ci-test-operator/emailAddress=ci-test-operator@example.invalid' >/dev/null 2>&1
  printf 'subjectAltName=email:ci-test-operator@example.invalid\nextendedKeyUsage=clientAuth\n' >"$dir/operator.ext"
  openssl x509 -req -in "$dir/operator.csr" -CA "$dir/ca.pem" -CAkey "$dir/ca.key" -CAcreateserial -out "$dir/operator.pem" -days 1 -extfile "$dir/operator.ext" >/dev/null 2>&1
  chmod 0600 "$dir"/*.key

  docker run --detach --name "$name" --publish "127.0.0.1:${port}:8443" \
    --env KC_BOOTSTRAP_ADMIN_USERNAME=admin --env "KC_BOOTSTRAP_ADMIN_PASSWORD=$password" \
    --env KC_HTTPS_CERTIFICATE_FILE=/opt/keycloak/conf/server.pem \
    --env KC_HTTPS_CERTIFICATE_KEY_FILE=/opt/keycloak/conf/server.key \
    --env KC_HTTPS_TRUST_STORE_FILE=/opt/keycloak/conf/ca.pem \
    --env KC_HTTPS_CLIENT_AUTH=request --env "KC_HOSTNAME=https://localhost:${port}" \
    --volume "$dir/server.pem:/opt/keycloak/conf/server.pem:ro" \
    --volume "$dir/server.key:/opt/keycloak/conf/server.key:ro" \
    --volume "$dir/ca.pem:/opt/keycloak/conf/ca.pem:ro" \
    quay.io/keycloak/keycloak:26.8.0@sha256:b0f60d489d51c5d113390bdf5461d4c06e6051be026c05549f2e1e10ec352bcc start-dev --https-port=8443 >/dev/null

  local ready=0
  for _ in $(seq 1 90); do
    if curl --silent --fail --cacert "$dir/ca.pem" "https://localhost:${port}/realms/master/.well-known/openid-configuration" >/dev/null 2>&1; then ready=1; break; fi
    sleep 2
  done
  [ "$ready" = 1 ] || { echo "CI test Keycloak did not become ready." >&2; docker logs "$name" >&2 || true; return 1; }
  token="$(curl --silent --show-error --cacert "$dir/ca.pem" --data-urlencode grant_type=password --data-urlencode client_id=admin-cli --data-urlencode username=admin --data-urlencode "password=$password" "https://localhost:${port}/realms/master/protocol/openid-connect/token" | jq -er .access_token)"
  curl --silent --show-error --cacert "$dir/ca.pem" -H "Authorization: Bearer $token" -H 'Content-Type: application/json' --data '{"realm":"demo-operator-test","enabled":true,"registrationAllowed":false}' "$base" >/dev/null
  curl --silent --show-error --cacert "$dir/ca.pem" -H "Authorization: Bearer $token" -H 'Content-Type: application/json' --data '{"username":"ci-test-operator","email":"ci-test-operator@example.invalid","firstName":"CI","lastName":"Operator","enabled":true,"emailVerified":true}' "$base/demo-operator-test/users" >/dev/null
  user_id="$(curl --silent --show-error --cacert "$dir/ca.pem" -H "Authorization: Bearer $token" "$base/demo-operator-test/users?username=ci-test-operator" | jq -er '.[0].id')"
  curl --silent --show-error --cacert "$dir/ca.pem" -H "Authorization: Bearer $token" -H 'Content-Type: application/json' --data "{\"clientId\":\"baha-ci-test\",\"enabled\":true,\"publicClient\":true,\"standardFlowEnabled\":true,\"directAccessGrantsEnabled\":false,\"redirectUris\":[\"http://127.0.0.1:${callback_port}/callback\"],\"attributes\":{\"pkce.code.challenge.method\":\"S256\"}}" "$base/demo-operator-test/clients" >/dev/null

  curl --silent --show-error --cacert "$dir/ca.pem" -H "Authorization: Bearer $token" -H 'Content-Type: application/json' --data '{"newName":"test-x509-browser"}' "$base/demo-operator-test/authentication/flows/browser/copy" >/dev/null
  curl --silent --show-error --cacert "$dir/ca.pem" -H "Authorization: Bearer $token" -H 'Content-Type: application/json' --data '{"provider":"auth-x509-client-username-form"}' "$base/demo-operator-test/authentication/flows/test-x509-browser/executions/execution" >/dev/null
  execution="$(curl --silent --show-error --cacert "$dir/ca.pem" -H "Authorization: Bearer $token" "$base/demo-operator-test/authentication/flows/test-x509-browser/executions" | jq -er '.[] | select(.providerId == "auth-x509-client-username-form") | .id')"
  curl --silent --show-error --cacert "$dir/ca.pem" -H "Authorization: Bearer $token" -H 'Content-Type: application/json' --data '{"alias":"test-client-certificate","config":{"x509-cert-auth.mapping-source-selection":"Subject\u0027s Common Name","x509-cert-auth.mapper-selection":"Username or Email","x509-cert-auth.confirmation-page-disallowed":"true","x509-cert-auth.certificate-ca":"CN=BaseHarbor ephemeral operator-test CA"}}' "$base/demo-operator-test/authentication/executions/$execution/config" >/dev/null
  curl --silent --show-error --cacert "$dir/ca.pem" -H "Authorization: Bearer $token" -H 'Content-Type: application/json' --data "{\"id\":\"$execution\",\"requirement\":\"ALTERNATIVE\"}" -X PUT "$base/demo-operator-test/authentication/flows/test-x509-browser/executions" >/dev/null
  curl --silent --show-error --cacert "$dir/ca.pem" -H "Authorization: Bearer $token" "$base/demo-operator-test" | jq '.browserFlow="test-x509-browser"' >"$dir/realm.json"
  curl --silent --show-error --cacert "$dir/ca.pem" -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -X PUT --data-binary @"$dir/realm.json" "$base/demo-operator-test" >/dev/null

  export BASEHARBOR_OPERATOR_OIDC_ISSUER="$realm_url"
  export BASEHARBOR_OPERATOR_OIDC_CLIENT_ID=baha-ci-test
  export BASEHARBOR_OPERATOR_OIDC_CA_FILE="$dir/ca.pem"
  export BASEHARBOR_OPERATOR_OIDC_CALLBACK_PORT="$callback_port"
  export BASEHARBOR_NO_BROWSER=1
  export BASEHARBOR_OPERATOR_TEST_CERT_FILE="$dir/operator.pem"
  export BASEHARBOR_OPERATOR_TEST_KEY_FILE="$dir/operator.key"
  "$BAHA" login -e test --no-browser >"$dir/login.log" 2>&1 &
  login_pid=$!
  auth_url=""
  for _ in $(seq 1 40); do
    auth_url="$(sed -n 's/^\(https:\/\/localhost:[^ ]*\)$/\1/p' "$dir/login.log" | head -n1)"
    [ -n "$auth_url" ] && break
    if ! kill -0 "$login_pid" 2>/dev/null; then cat "$dir/login.log" >&2; wait "$login_pid" || true; return 1; fi
    sleep 0.25
  done
  [ -n "$auth_url" ] || { echo "baha login did not emit its authorization URL." >&2; cat "$dir/login.log" >&2; kill "$login_pid" 2>/dev/null || true; wait "$login_pid" || true; return 1; }
  # auth-code-file is read before the generated URL is printed, so a harness
  # cannot obtain the PKCE challenge for that hook. The existing no-browser
  # loopback callback accepts the same authorization-code flow and is driven
  # here with curl presenting the ephemeral test certificate to Keycloak.
  curl --silent --show-error --fail --location --max-redirs 5 --cacert "$dir/ca.pem" --cert "$BASEHARBOR_OPERATOR_TEST_CERT_FILE" --key "$BASEHARBOR_OPERATOR_TEST_KEY_FILE" "$auth_url" >/dev/null
  wait "$login_pid" || { cat "$dir/login.log" >&2; return 1; }
  grep -Fq "Authenticated operator: $user_id" "$dir/login.log" || { echo "baha authenticated as an unexpected operator." >&2; cat "$dir/login.log" >&2; return 1; }
}

operator_test_idp_cleanup() {
  [ -z "${OPERATOR_TEST_IDP_NAME:-}" ] || docker rm --force "$OPERATOR_TEST_IDP_NAME" >/dev/null 2>&1 || true
  [ -z "${OPERATOR_TEST_IDP_DIR:-}" ] || rm -rf -- "$OPERATOR_TEST_IDP_DIR"
}
