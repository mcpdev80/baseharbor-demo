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
  (
    # Full journeys already have a Core; the negative case owns isolated state.
    export BASEHARBOR_STATE_DIR="$workdir/no-core-state"
    export BASEHARBOR_TARGET=init-consent-fixture
    "$BAHA" target create "$BASEHARBOR_TARGET" --provider docker --access local-docker --reference local --scope default --default >/dev/null
    if "$BAHA" init --quick --json > "$ARTIFACT_DIR/init-no-core.json" 2>&1; then
      fail "Initialization consent" "fresh noninteractive initialization accepted a missing Core"
    fi
    jq -e '.error.cause == "core_required"' "$ARTIFACT_DIR/init-no-core.json" >/dev/null
  )
  test ! -e baseharbor.yaml
  test ! -e .baseharbor
  python3 "$DEMO_ROOT/tests/static-adopt-fixture.py" "$BAHA" "$workdir" demo demo-app "$ARTIFACT_DIR/source-adopt.json"
  manifest_before="$(sha256sum baseharbor.yaml | awk '{print $1}')"
  "$BAHA" init --quick | tee "$ARTIFACT_DIR/init-quick.txt"
  test "$manifest_before" = "$(sha256sum baseharbor.yaml | awk '{print $1}')"
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

# Suggested-only OTLP/log collection and heuristic secret names are intentionally
# not promoted into the portable contract by --quick.
assert_no_grep_match -q '^telemetry:' "$workdir/baseharbor.yaml"
assert_no_grep_match -q '^logs:' "$workdir/baseharbor.yaml"
assert_no_grep_match -q '^secrets:' "$workdir/baseharbor.yaml"

pass "Repository Inspection" "read-only human + standardized source-resolution JSON"
pass "Initialization consent" "missing Core fails closed without repository mutation; real first-use bootstrap is covered by native guided gates"
pass "Application Init Quick" "explicit MCP source authoring and idempotent CLI quick init preserve source-neutral workload.components and existing intent"
