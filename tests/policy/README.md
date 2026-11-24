# Managed policy operator certificate fixture

When the `CI` marker is present, `run.sh` provisions a disposable Keycloak 26.8.0 issuer for the managed-policy acceptance gate and logs `baha` in as `ci-test-operator` using a generated X.509 client certificate. Without `CI`, the fixture is not sourced and the existing local behavior is unchanged.

The fixture creates an ephemeral CA. It signs both the HTTPS certificate served by the test Keycloak and a client certificate with `CN=ci-test-operator`. Keycloak trusts that CA for client TLS and maps the certificate common name to the pre-created test user in its isolated `demo-operator-test` realm. Its OIDC client is public, Standard Flow only, and requires PKCE S256; direct access grants and service accounts are disabled. `baha` trusts the same CA for OIDC discovery and code exchange.

The harness invokes the existing `baha login -e dev --no-browser` Authorization Code + PKCE flow, reads its generated authorization URL, then uses `curl` with the test certificate to complete the Keycloak X.509 browser flow and return through baha's loopback callback. It does not add a grant type, alter client authentication, route around operator authentication, or change consent behavior.

The auth-code-file option is not used for this flow: in the current Core implementation `internal/operatorauth/login.go` reads that file before it emits the generated state and PKCE authorization URL, so the harness cannot obtain the challenge needed to request the matching code. The existing no-browser loopback callback provides the demo-only headless driver without a Core change.

Private test keys, generated trust material, the Keycloak container, and its temporary admin account are removed by the policy gate's EXIT cleanup. These credentials are ephemeral test fixtures and must not be reused outside this gate.
