#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Application-facing observability"
api_host="demo.baha.localhost"
gateway_ca="$XDG_DATA_HOME/baseharbor/targets/$BASEHARBOR_TARGET/developer-access/dev/gateway/runtime/ca.pem"
test -s "$gateway_ca"
gateway_port="$(dev_gateway_port)"
base="$(dev_gateway_url "$api_host")"
curl_dev=(curl -fsS --cacert "$gateway_ca" --resolve "$api_host:$gateway_port:127.0.0.1")

"${curl_dev[@]}" "$base/healthz" | jq -e '.status=="ok"' >/dev/null
"${curl_dev[@]}" "$base/metrics" | tee "$ARTIFACT_DIR/metrics.txt" | grep -q '^baseharbor_demo_requests_total '
"${curl_dev[@]}" -X POST "$base/api/metrics/verify" | tee "$ARTIFACT_DIR/metrics-verify.json" | jq -e '.present==true and .metric=="baseharbor_demo_requests_total"' >/dev/null
pass "Metrics" "OpenMetrics endpoint + application verification action"

"${curl_dev[@]}" -X POST "$base/api/trace" | tee "$ARTIFACT_DIR/trace.json" | jq -e '.export_configured==true' >/dev/null
pass "Telemetry / Traces" "real OpenTelemetry span emitted"

"$BAHA" app logs demo-app > "$ARTIFACT_DIR/app-logs.txt"
grep -q '"event":"request"' "$ARTIFACT_DIR/app-logs.txt"
pass "Logs" "structured workload logs observable"
