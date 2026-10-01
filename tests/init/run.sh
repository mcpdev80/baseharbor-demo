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
  "$BAHA" app init --quick | tee "$ARTIFACT_DIR/init-quick.txt"
)

after="$(sha256sum "$workdir/compose.yaml" | awk '{print $1}')"
test "$before" = "$after"
test -s "$workdir/baseharbor.yaml"

grep -q '^workload:' "$workdir/baseharbor.yaml"
grep -q '^  components:' "$workdir/baseharbor.yaml"
! grep -q '^  compose:' "$workdir/baseharbor.yaml"
! grep -q '^  services:' "$workdir/baseharbor.yaml"
grep -q '^  components:' "$workdir/baseharbor.yaml"
grep -q '^    - demo-app
grep -q '^runtime:' "$workdir/baseharbor.yaml"

# Suggested-only OTLP/log collection and heuristic secret names are intentionally
# not promoted into the portable contract by --quick.
! grep -q '^telemetry:' "$workdir/baseharbor.yaml"
! grep -q '^logs:' "$workdir/baseharbor.yaml"
! grep -q '^secrets:' "$workdir/baseharbor.yaml"

pass "Repository Inspection" "read-only human + standardized source-resolution JSON"
pass "Application Init Quick" "single-source Compose -> source-neutral workload.components; no repository source metadata needed"
 "$workdir/baseharbor.yaml"
! grep -q '^  compose:' "$workdir/baseharbor.yaml"
test ! -e "$workdir/baseharbor.repository.yaml"
jq -e '.workload_source_resolution.state == "selected"' "$ARTIFACT_DIR/inspect.json" >/dev/null
jq -e '.workload_source_resolution.reason == "single_candidate"' "$ARTIFACT_DIR/inspect.json" >/dev/null
jq -e '.workload_evidence.components[] | select(.id == "demo-app")' "$ARTIFACT_DIR/inspect.json" >/dev/null
grep -q '^metrics:' "$workdir/baseharbor.yaml"
grep -q '^runtime:' "$workdir/baseharbor.yaml"

# Suggested-only OTLP/log collection and heuristic secret names are intentionally
# not promoted into the portable contract by --quick.
! grep -q '^telemetry:' "$workdir/baseharbor.yaml"
! grep -q '^logs:' "$workdir/baseharbor.yaml"
! grep -q '^secrets:' "$workdir/baseharbor.yaml"

pass "Repository Inspection" "read-only human + JSON"
pass "Application Init Quick" "unambiguous detected intent only; no manual YAML mutation"
