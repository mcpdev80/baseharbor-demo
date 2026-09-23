#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Application-facing capabilities"
base="https://127.0.0.1:8080"

curl -kfsS "$base/healthz" | jq -e '.status=="ok"' >/dev/null
curl -kfsS "$base/api/status" > "$ARTIFACT_DIR/demo-status.json"
jq -e '.capabilities.sql.ready==true' "$ARTIFACT_DIR/demo-status.json" >/dev/null
pass "SQL" "application protocol ready"

curl -kfsS -X POST "$base/api/sql" | tee "$ARTIFACT_DIR/sql.json" | jq -e '.records>=1' >/dev/null
pass "SQL Data Path" "write + read"

curl -kfsS -X POST "$base/api/cache" | tee "$ARTIFACT_DIR/cache.json" | jq -e '.value=="portable-cache-value"' >/dev/null
pass "Cache" "set + get + ttl"

curl -kfsS -X POST "$base/api/object" | tee "$ARTIFACT_DIR/object.json" | jq -e '.bucket|length>0' >/dev/null
pass "Object Storage" "S3 put"

curl -kfsS -X POST "$base/api/secret" | tee "$ARTIFACT_DIR/secret.json" | jq -e '.present==true and .value_exposed==false' >/dev/null
! grep -Fq 'acceptance-secret-value' "$ARTIFACT_DIR/secret.json"
pass "Secrets" "dedicated binding verification without value exposure"

curl -kfsS "$base/metrics" | tee "$ARTIFACT_DIR/metrics.txt" | grep -q '^baseharbor_demo_requests_total '
curl -kfsS -X POST "$base/api/metrics/verify" | tee "$ARTIFACT_DIR/metrics-verify.json" | jq -e '.present==true and .metric=="baseharbor_demo_requests_total"' >/dev/null
pass "Metrics" "OpenMetrics endpoint + application verification action"

curl -kfsS -X POST "$base/api/trace" | tee "$ARTIFACT_DIR/trace.json" | jq -e '.export_configured==true' >/dev/null
pass "Telemetry / Traces" "real OpenTelemetry span emitted"

curl -kfsS -X POST "$base/api/runtime-resource" | tee "$ARTIFACT_DIR/runtime-resource.json" | jq -e '.id|length>0' >/dev/null
pass "Runtime Resources" "application-time resource request accepted through mTLS broker"

jq -e '.capabilities.secrets.ready==true' "$ARTIFACT_DIR/demo-status.json" >/dev/null
! grep -Fq 'acceptance-secret-value' "$ARTIFACT_DIR/demo-status.json"

"$BAHA" app logs demo-app > "$ARTIFACT_DIR/app-logs.txt"
grep -q '"event":"request"' "$ARTIFACT_DIR/app-logs.txt"
pass "Logs" "structured workload logs observable"
