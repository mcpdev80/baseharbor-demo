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

runtime_env="$XDG_DATA_HOME/baseharbor/targets/$BASEHARBOR_TARGET/apps/demo/dev/runtime.env"
override="$XDG_DATA_HOME/baseharbor/targets/$BASEHARBOR_TARGET/apps/demo/dev/workload.override.yaml"
echo "[diag] runtime S3 keys:"
if [ -s "$runtime_env" ]; then
  sed -n 's/^\(S3_[A-Z0-9_]*\)=.*/\1=<present>/p; s/^\(AWS_[A-Z0-9_]*\)=.*/\1=<present>/p' "$runtime_env" || true
fi
echo "[diag] workload override S3 keys:"
if [ -s "$override" ]; then
  grep -E 'S3_|AWS_' "$override" | sed -E 's/: .*$/: <present>/' || true
fi
container_id="$(container_id_for_service demo-app)"
echo "[diag] workload container S3 keys:"
if [ -n "$container_id" ]; then
  "$CONTAINER_CLI" inspect "$container_id" --format '{{range .Config.Env}}{{println .}}{{end}}' \
    | sed -n 's/^\(S3_[A-Z0-9_]*\)=.*/\1=<present>/p; s/^\(AWS_[A-Z0-9_]*\)=.*/\1=<present>/p' || true
fi

object_code="$("${curl_dev[@]/-fsS/-sS}" -o "$ARTIFACT_DIR/object.json" -w '%{http_code}' -X POST "$base/api/object" || true)"
cat "$ARTIFACT_DIR/object.json"
test "$object_code" = "200"
jq -e '.bucket|length>0' "$ARTIFACT_DIR/object.json" >/dev/null
pass "Object Storage" "S3 put"

"${curl_dev[@]}" -X POST "$base/api/secret" | tee "$ARTIFACT_DIR/secret.json" | jq -e '.present==true and .value_exposed==false' >/dev/null
! grep -Fq 'acceptance-secret-value' "$ARTIFACT_DIR/secret.json"
jq -e '.capabilities.secrets.ready==true' "$ARTIFACT_DIR/data-status.json" >/dev/null
pass "Secrets" "dedicated binding verification without value exposure"

"${curl_dev[@]}" -X POST "$base/api/runtime-resource" | tee "$ARTIFACT_DIR/runtime-resource.json" | jq -e '.id|length>0' >/dev/null
pass "Runtime Resources" "application-time resource request accepted through mTLS broker"

assert_no_secret_leak "$ARTIFACT_DIR/data-status.json"
