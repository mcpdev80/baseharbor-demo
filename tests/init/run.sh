#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Read-only inspection and deterministic init"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

cp "$DEMO_ROOT/compose.yaml" "$workdir/compose.yaml"
cp -a "$DEMO_ROOT/demo-app" "$workdir/demo-app"

before="$(sha256sum "$workdir/compose.yaml" | awk '{print $1}')"

(
  cd "$workdir"
  "$BAHA" app inspect . | tee "$ARTIFACT_DIR/inspect.txt"
  "$BAHA" app inspect . -o json > "$ARTIFACT_DIR/inspect.json"
  jq -e . "$ARTIFACT_DIR/inspect.json" >/dev/null
)

if [ -z "$CONTAINER_CLI" ]; then
  (
    cd "$workdir"
    if "$BAHA" --no-input app init --quick > "$ARTIFACT_DIR/init-core-required.txt" 2>&1; then
      fail "Core prerequisite" "init unexpectedly succeeded without Core"
      exit 1
    fi
    grep -Fq 'BaseHarbor needs its Core services before the first application can run.' "$ARTIFACT_DIR/init-core-required.txt"
    if "$BAHA" --no-input app init demo --sql -o json > "$ARTIFACT_DIR/init-core-required.out" 2> "$ARTIFACT_DIR/init-core-required.json"; then
      fail "Core prerequisite" "deterministic init unexpectedly succeeded without Core"
      exit 1
    fi
    test ! -s "$ARTIFACT_DIR/init-core-required.out"
    jq -e '.error.code == "capability_missing" and .error.cause == "core_required" and .error.retryable == true' "$ARTIFACT_DIR/init-core-required.json" >/dev/null
  )
  test "$before" = "$(sha256sum "$workdir/compose.yaml" | awk '{print $1}')"
  test ! -e "$workdir/baseharbor.yaml"
  test ! -e "$workdir/baseharbor.repository.yaml"
  test ! -e "$workdir/.baseharbor"
  jq -e '.workload_source_resolution.state == "selected" and .workload_source_resolution.selected.path == "compose.yaml"' "$ARTIFACT_DIR/inspect.json" >/dev/null
  jq -e '.workload_evidence.components[] | select(.id == "demo-app")' "$ARTIFACT_DIR/inspect.json" >/dev/null
  assert_no_secret_leak "$ARTIFACT_DIR/init-core-required.json"
  pass "Repository Inspection" "read-only inspection remains available before Core setup"
  pass "Core prerequisite" "non-interactive quick and deterministic init fail closed without source mutation"
  exit 0
fi

# Positive quick-init is exercised after real Core setup in the native guided
# journey. No static fixture manufactures READY installation state.
(
  cd "$workdir"
  "$BAHA" --no-input app init --quick | tee "$ARTIFACT_DIR/init-quick.txt"
)

after="$(sha256sum "$workdir/compose.yaml" | awk '{print $1}')"
test "$before" = "$after"
test -s "$workdir/baseharbor.yaml"

grep -q '^workload:' "$workdir/baseharbor.yaml"
grep -q '^  components:' "$workdir/baseharbor.yaml"
grep -q '^    - demo-app$' "$workdir/baseharbor.yaml"
assert_no_grep_match -q '^  compose:' "$workdir/baseharbor.yaml"
assert_no_grep_match -q '^  services:' "$workdir/baseharbor.yaml"
test ! -e "$workdir/baseharbor.repository.yaml"

jq -e '.workload_source_resolution.schema_version == "baseharbor.workload-source-resolution/v1"' "$ARTIFACT_DIR/inspect.json" >/dev/null
jq -e '.workload_source_resolution.state == "selected"' "$ARTIFACT_DIR/inspect.json" >/dev/null
jq -e '.workload_source_resolution.reason == "single_candidate"' "$ARTIFACT_DIR/inspect.json" >/dev/null
jq -e '.workload_source_resolution.selected.kind == "compose"' "$ARTIFACT_DIR/inspect.json" >/dev/null
jq -e '.workload_source_resolution.selected.path == "compose.yaml"' "$ARTIFACT_DIR/inspect.json" >/dev/null
jq -e '.workload_evidence.components[] | select(.id == "demo-app")' "$ARTIFACT_DIR/inspect.json" >/dev/null

grep -q '^runtime:' "$workdir/baseharbor.yaml"

# Suggested-only OTLP/log collection and heuristic secret names are intentionally
# not promoted into the portable contract by --quick.
assert_no_grep_match -q '^telemetry:' "$workdir/baseharbor.yaml"
assert_no_grep_match -q '^logs:' "$workdir/baseharbor.yaml"
assert_no_grep_match -q '^secrets:' "$workdir/baseharbor.yaml"

pass "Repository Inspection" "read-only human + standardized source-resolution JSON"
pass "Application Init Quick" "single-source Compose -> source-neutral workload.components; no source metadata needed"
