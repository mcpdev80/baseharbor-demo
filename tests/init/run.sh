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
    # Source-only initialization owns isolated state and never installs Core.
    export BASEHARBOR_STATE_DIR="$workdir/no-core-state"
    export BASEHARBOR_TARGET=init-source-fixture
    "$BAHA" target create "$BASEHARBOR_TARGET" --provider docker --access local-docker --reference local --scope default --default >/dev/null
    source_root="$workdir/source-only"
    mkdir -p "$source_root"
    cp "$DEMO_ROOT/compose.yaml" "$source_root/compose.yaml"
    cp -a "$DEMO_ROOT/demo-app" "$source_root/demo-app"
    cd "$source_root"
    "$BAHA" init --quick --json > "$ARTIFACT_DIR/init-no-core.json"
    jq -e '.application_id | test("^[0-9a-f-]{36}$")' "$ARTIFACT_DIR/init-no-core.json" >/dev/null
    test -d .baseharbor
    assert_no_grep_match -q '^  id:' baseharbor.yaml
    original="$(sha256sum baseharbor.yaml | awk '{print $1}')"
    "$BAHA" init --quick --json > "$ARTIFACT_DIR/init-no-core-repeat.json"
    test "$original" = "$(sha256sum baseharbor.yaml | awk '{print $1}')"
    test ! -e "$BASEHARBOR_STATE_DIR/targets/$BASEHARBOR_TARGET/core/runtime.env"
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
pass "Source-only initialization" "no Core or login prerequisite; stable system identity and repeat init preserve authored source; runtime remains separately qualified"
pass "Application Init Quick" "explicit MCP source authoring and idempotent CLI quick init preserve source-neutral workload.components and existing intent"
