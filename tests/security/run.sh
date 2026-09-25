#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Workload security"
tmp="$(mktemp)"
cp "$DEMO_ROOT/compose.yaml" "$tmp"
trap 'cp "$tmp" "$DEMO_ROOT/compose.yaml"; rm -f "$tmp"' EXIT

python3 - "$DEMO_ROOT/compose.yaml" <<'PY'
from pathlib import Path
p = Path(__import__("sys").argv[1])
s = p.read_text()
s = s.replace("    restart: unless-stopped\n\n  postgres:", "    restart: unless-stopped\n    privileged: true\n\n  postgres:", 1)
p.write_text(s)
PY

set +e
(
  cd "$DEMO_ROOT"
  "$BAHA" app preflight
) >"$ARTIFACT_DIR/security-privileged.txt" 2>&1
rc=$?
set -e
test "$rc" -ne 0
pass "Workload Security" "privileged workload denied before mutation"

cp "$tmp" "$DEMO_ROOT/compose.yaml"
trap - EXIT
rm -f "$tmp"


section "TLS file binding boundary"

(
  cd "$DEMO_ROOT"
  "$BAHA" app exec demo-app /bin/sh -ec '
  test -n "$DATABASE_CA_FILE"
  test -n "$REDIS_CA_FILE"
  test -n "$AWS_CA_BUNDLE"
  test -n "$OTEL_EXPORTER_OTLP_CERTIFICATE"
  test -n "$TLS_CERT_FILE"
  test -n "$TLS_KEY_FILE"
  test -n "$BASEHARBOR_RUNTIME_CA_FILE"
  test -n "$BASEHARBOR_RUNTIME_CLIENT_CERT_FILE"
  test -n "$BASEHARBOR_RUNTIME_CLIENT_KEY_FILE"

  test -s "$DATABASE_CA_FILE"
  test -s "$REDIS_CA_FILE"
  test -s "$AWS_CA_BUNDLE"
  test -s "$OTEL_EXPORTER_OTLP_CERTIFICATE"
  test -s "$TLS_CERT_FILE"
  test -s "$TLS_KEY_FILE"
  test -s "$BASEHARBOR_RUNTIME_CA_FILE"
  test -s "$BASEHARBOR_RUNTIME_CLIENT_CERT_FILE"
  test -s "$BASEHARBOR_RUNTIME_CLIENT_KEY_FILE"
'
)

base="https://127.0.0.1:8080"
curl -kfsS -X POST "$base/api/sql" | jq -e '.records>=1' >/dev/null
curl -kfsS -X POST "$base/api/cache" | jq -e '.value=="portable-cache-value"' >/dev/null
curl -kfsS -X POST "$base/api/object" | jq -e '.bucket|length>0' >/dev/null
curl -kfsS -X POST "$base/api/trace" | jq -e '.export_configured==true' >/dev/null

pass "TLS File Bindings" "environment exposes paths only; CA/cert/key material is mounted as files and consumed by the workload"
