#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Guided pristine-repository happy path"

clean_generated_state
rm -rf "$BASEHARBOR_STATE_DIR"
rm -f "$ARTIFACT_DIR/openbao-recovery.json"

test ! -e "$DEMO_ROOT/baseharbor.yaml"
test ! -e "$DEMO_ROOT/.baseharbor"

compose_before="$(sha256sum "$DEMO_ROOT/compose.yaml" | awk '{print $1}')"

set +e
python3 "$DEMO_ROOT/tests/guided/drive.py"
guided_rc=$?
set -e

if [ "$guided_rc" -ne 0 ]; then
  # A failed guided run can mean either an isolated application component failed
  # or the BaseHarbor runtime never came up at all. Only the latter is fatal to
  # the entire acceptance environment.
  runtime_status="$ARTIFACT_DIR/guided-failure-status.json"
  runtime_stderr="$ARTIFACT_DIR/guided-failure-status.stderr.txt"
  status_rc=1

  if [ -s "$DEMO_ROOT/baseharbor.yaml" ]; then
    set +e
    (
      cd "$DEMO_ROOT"
      "$BAHA" status -o json >"$runtime_status" 2>"$runtime_stderr"
    )
    status_rc=$?
    set -e
  fi

  if [ -s "$runtime_status" ] && jq -e '.state == "running"' "$runtime_status" >/dev/null 2>&1; then
    echo "Guided acceptance failed, but the application runtime is running; treating this as a collectable gate failure." >&2
    exit "$guided_rc"
  fi

  echo "Guided acceptance failed before a usable application runtime was established; remaining runtime-dependent acceptance is not meaningful." >&2
  if [ -s "$runtime_status" ]; then
    cat "$runtime_status" >&2 || true
  elif [ -s "$runtime_stderr" ]; then
    cat "$runtime_stderr" >&2 || true
  fi
  exit 70
fi

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
