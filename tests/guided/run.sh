#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Guided pristine-repository happy path"

clean_generated_state
rm -rf "$XDG_CONFIG_HOME/baseharbor" "$XDG_DATA_HOME/baseharbor"
"$BAHA" target create "$BASEHARBOR_TARGET" \
  --provider "$BASEHARBOR_TEST_RUNTIME" \
  --access "local-$BASEHARBOR_TEST_RUNTIME" \
  --reference local \
  --scope default \
  --default >/dev/null
rm -f "$ARTIFACT_DIR/openbao-recovery.json"

test ! -e "$DEMO_ROOT/baseharbor.yaml"
test ! -e "$DEMO_ROOT/.baseharbor"

compose_before="$(sha256sum "$DEMO_ROOT/compose.yaml" | awk '{print $1}')"

python3 "$DEMO_ROOT/tests/guided/drive.py"

test -s "$DEMO_ROOT/baseharbor.yaml"
compose_after="$(sha256sum "$DEMO_ROOT/compose.yaml" | awk '{print $1}')"
test "$compose_before" = "$compose_after"

grep -q '^workload:' "$DEMO_ROOT/baseharbor.yaml"
grep -q '^metrics:' "$DEMO_ROOT/baseharbor.yaml"
grep -q '^telemetry:' "$DEMO_ROOT/baseharbor.yaml"
grep -q '^logs:' "$DEMO_ROOT/baseharbor.yaml"
grep -q '^runtime:' "$DEMO_ROOT/baseharbor.yaml"
grep -q 'APP_SECRET' "$DEMO_ROOT/baseharbor.yaml"
grep -q 'uploads' "$DEMO_ROOT/baseharbor.yaml"

(
  cd "$DEMO_ROOT"
  "$BAHA" status | tee "$ARTIFACT_DIR/guided-status.txt"
  "$BAHA" doctor | tee "$ARTIFACT_DIR/guided-doctor.txt"
)

grep -q '^READY' "$ARTIFACT_DIR/guided-doctor.txt"
assert_no_secret_leak "$ARTIFACT_DIR/guided-init.txt"
assert_no_secret_leak "$ARTIFACT_DIR/guided-up.txt"
assert_no_secret_leak "$ARTIFACT_DIR/guided-status.txt"
assert_no_secret_leak "$ARTIFACT_DIR/guided-doctor.txt"

pass "Guided Adoption Happy Path" "pristine repository -> interactive app init -> interactive baha up -> READY"
