#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Application-facing data capabilities"
api_host="demo.baha.localhost"
gateway_ca="$XDG_DATA_HOME/baseharbor/targets/$BASEHARBOR_TARGET/developer-access/dev/gateway/runtime/ca.pem"
test -s "$gateway_ca"
gateway_port="$(dev_gateway_port)"
base="$(dev_gateway_url "$api_host")"
curl_dev=(curl -fsS --cacert "$gateway_ca" --resolve "$api_host:$gateway_port:127.0.0.1")

"${curl_dev[@]}" "$base/healthz" | jq -e '.status=="ok"' >/dev/null
"${curl_dev[@]}" "$base/api/status" > "$ARTIFACT_DIR/data-status.json"
jq -e '.capabilities.sql.ready==true' "$ARTIFACT_DIR/data-status.json" >/dev/null
"${curl_dev[@]}" -X POST "$base/api/sql" | tee "$ARTIFACT_DIR/sql.json" | jq -e '.records>=1' >/dev/null
pass "SQL Data Path" "write + read"

"${curl_dev[@]}" -X POST "$base/api/cache" | tee "$ARTIFACT_DIR/cache.json" | jq -e '.value=="portable-cache-value"' >/dev/null
pass "Cache" "set + get + ttl"

object_code="$(curl -sS --cacert "$gateway_ca" --resolve "$api_host:$gateway_port:127.0.0.1" -o "$ARTIFACT_DIR/object.json" -w '%{http_code}' -X POST "$base/api/object" || true)"
if [ "$object_code" != "200" ]; then
  echo "Object Storage API returned HTTP $object_code" >&2
  cat "$ARTIFACT_DIR/object.json" >&2 || true
  (cd "$DEMO_ROOT" && "$BAHA" status --verbose) > "$ARTIFACT_DIR/object-status.txt" 2>&1 || true
  exit 1
fi
jq -e '.bucket|length>0' "$ARTIFACT_DIR/object.json" >/dev/null
pass "Object Storage" "S3 put"

"${curl_dev[@]}" -X POST "$base/api/secret" | tee "$ARTIFACT_DIR/secret.json" | jq -e '.present==true and .value_exposed==false' >/dev/null
! grep -Fq 'acceptance-secret-value' "$ARTIFACT_DIR/secret.json"
jq -e '.capabilities.secrets.ready==true' "$ARTIFACT_DIR/data-status.json" >/dev/null
pass "Secrets" "dedicated binding verification without value exposure"

"${curl_dev[@]}" -X POST "$base/api/runtime-resource" | tee "$ARTIFACT_DIR/runtime-resource.json" | jq -e '.id|length>0' >/dev/null
pass "Runtime Resources" "application-time resource request accepted through mTLS broker"

assert_no_secret_leak "$ARTIFACT_DIR/data-status.json"
