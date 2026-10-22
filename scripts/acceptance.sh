#!/usr/bin/env bash
set -euo pipefail

DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEMO_ROOT
export ARTIFACT_DIR="${ARTIFACT_DIR:-$DEMO_ROOT/artifacts}"
export BASEHARBOR_INSTALL_DIR="${BASEHARBOR_INSTALL_DIR:-$DEMO_ROOT/.tools/bin}"
GATE_REGISTRY="$DEMO_ROOT/tests/gates.json"
SUITE_REGISTRY="$DEMO_ROOT/tests/pre-release-suites.json"

mkdir -p "$ARTIFACT_DIR" "$BASEHARBOR_INSTALL_DIR"
: > "$ARTIFACT_DIR/results.tsv"
: > "$ARTIFACT_DIR/groups.tsv"

jq -e '
  type == "array" and length > 0 and
  all(.[];
    (.name | type == "string" and length > 0) and
    (.requires | type == "array") and
    all(.requires[]; type == "string" and length > 0)
  )
' "$GATE_REGISTRY" >/dev/null

jq -e --slurpfile gates "$GATE_REGISTRY" '
  type == "object" and length > 0 and
  all(to_entries[];
    (.value | type == "array" and length > 0) and
    all(.value[]; type == "string" and length > 0)
  ) and
  ([.[][]] | length) == ($gates[0] | length) and
  ([.[][]] | sort) == ([$gates[0][].name] | sort)
' "$SUITE_REGISTRY" >/dev/null

if [ -n "${BASEHARBOR_SOURCE_REF:-}" ]; then
  export BASEHARBOR_RUNTIME_IMAGE="${BASEHARBOR_RUNTIME_IMAGE:-localhost/baseharbor-runtime:demo-candidate-${BASEHARBOR_SOURCE_REF}}"
fi
printf '[acceptance] install: preparing BaseHarbor candidate\n'
bash "$DEMO_ROOT/scripts/install-baseharbor.sh"
export BAHA="$BASEHARBOR_INSTALL_DIR/baha"
printf '[acceptance] install: candidate ready (%s)\n' "$("$BAHA" version | head -n1)"
export BASEHARBOR_TEST_RUNTIME="${BASEHARBOR_TEST_RUNTIME:-docker}"
export BASEHARBOR_DEMO_FIXTURE="$(mktemp -d "${RUNNER_TEMP:-/tmp}/baseharbor-demo-fixture.XXXXXX")"
export XDG_CONFIG_HOME="$BASEHARBOR_DEMO_FIXTURE/config"
export XDG_DATA_HOME="$BASEHARBOR_DEMO_FIXTURE/data"
export BASEHARBOR_TARGET="${BASEHARBOR_TARGET:-demo-${BASEHARBOR_TEST_RUNTIME}}"
command -v "$BASEHARBOR_TEST_RUNTIME" >/dev/null 2>&1

rm -rf "$XDG_CONFIG_HOME/baseharbor" "$XDG_DATA_HOME/baseharbor" "$XDG_DATA_HOME/baseharbor-recovery"
printf '[acceptance] target: creating %s on %s\n' "$BASEHARBOR_TARGET" "$BASEHARBOR_TEST_RUNTIME"
"$BAHA" target create "$BASEHARBOR_TARGET" \
  --provider "$BASEHARBOR_TEST_RUNTIME" \
  --access "local-$BASEHARBOR_TEST_RUNTIME" \
  --reference local \
  --scope default \
  --default >/dev/null
printf '[acceptance] target: ready\n'

# BaseHarbor keeps Podman storage in the host runtime context. The demo's
# XDG directories isolate application state, not container storage.
runtime_cmd() {
  if [ "$BASEHARBOR_TEST_RUNTIME" = podman ]; then
    env -u XDG_CONFIG_HOME -u XDG_DATA_HOME podman "$@"
  else
    docker "$@"
  fi
}

cleanup() {
  status=$?
  # A cancellation enters the same bounded cleanup once. Further signals must
  # not interrupt the fresh owner/teardown context halfway through recovery.
  trap - EXIT
  trap '' INT TERM
  set +e
  cd "$DEMO_ROOT"
  printf '[acceptance] cleanup: begin (exit=%s)\n' "$status" >&2
  # Resume only exact native resources in Core's current read-only owner
  # inventory. A foreign paused sentinel is neither an error nor permission.
  cleanup_preparation=0
  bash "$DEMO_ROOT/scripts/failure-runtime-diagnostics.sh" cleanup-preparation --unpause-owned || cleanup_preparation=$?
  if [ "$status" -ne 0 ]; then
    bash "$DEMO_ROOT/scripts/failure-runtime-diagnostics.sh" cleanup || true
  fi

  printf '[acceptance] cleanup: destroy registered BaseHarbor state\n' >&2
  cleanup_result=success
  # Installation teardown includes provider handoffs and ordered native stops.
  # Match the fixture command budget; a 90-second outer timeout truncates valid cleanup.
  timeout --signal=TERM --kill-after=5s 900s python3 "$DEMO_ROOT/tests/fixture-consent.py" "$BAHA" destroy --all --yes >"$ARTIFACT_DIR/cleanup.json" 2>"$ARTIFACT_DIR/cleanup.stderr.txt"
  cleanup_exit=$?
  foreign_check=0
  foreign_remove=0
  # The heavy New/Edit gate hands off its own private sentinel receipt. Verify
  # preservation after the actual acceptance teardown, before its separate
  # exact-owner cleanup. A failed check must still attempt that bounded cleanup.
  if [ -e "$BASEHARBOR_DEMO_FIXTURE/new-edit-foreign.json" ] || [ -L "$BASEHARBOR_DEMO_FIXTURE/new-edit-foreign.json" ]; then
    timeout --signal=TERM --kill-after=5s 180s python3 "$DEMO_ROOT/tests/data-capabilities/new_edit.py" --foreign-check >"$ARTIFACT_DIR/foreign-check.txt" 2>&1 || foreign_check=$?
    timeout --signal=TERM --kill-after=5s 180s python3 "$DEMO_ROOT/tests/data-capabilities/new_edit.py" --foreign-remove >"$ARTIFACT_DIR/foreign-remove.txt" 2>&1 || foreign_remove=$?
  elif [ -e "$ARTIFACT_DIR/new-edit-sql.json" ] || [ -L "$ARTIFACT_DIR/new-edit-sql.json" ]; then
    foreign_check=1
    printf 'native New/Edit evidence lacks its private foreign sentinel owner receipt\n' >"$ARTIFACT_DIR/foreign-check.txt"
  fi
  if [ "$cleanup_exit" -ne 0 ] || [ "$cleanup_preparation" -ne 0 ] || [ "$foreign_check" -ne 0 ] || [ "$foreign_remove" -ne 0 ]; then
    cleanup_result=incomplete
    cat "$ARTIFACT_DIR/cleanup.stderr.txt" >&2
    printf '[acceptance] cleanup: incomplete (destroy=%s preparation=%s foreign-check=%s foreign-remove=%s); retained owner and diagnostics remain available\n' "$cleanup_exit" "$cleanup_preparation" "$foreign_check" "$foreign_remove" >&2
    [ "$status" -ne 0 ] || status=1
  else
    printf '[acceptance] cleanup: complete\n' >&2
  fi
  python3 - "$ARTIFACT_DIR/recovery-qualified.json" "$cleanup_result" "$status" <<'PY' || { [ "$status" -ne 0 ] || status=1; }
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
if path.is_file() and not path.is_symlink():
    receipt = json.loads(path.read_text())
    receipt['cleanup'] = sys.argv[2]
    if sys.argv[2] != 'success' or sys.argv[3] != '0':
        receipt['result'] = 'failure'
    path.write_text(json.dumps(receipt, indent=2) + '\n')
PY
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM


declare -A selected=()
declare -A gate_status=()
full_suite=0

gate_exists() {
  jq -e --arg gate "$1" 'any(.[]; .name == $gate)' "$GATE_REGISTRY" >/dev/null
}

select_gate() {
  local gate="$1"
  gate_exists "$gate" || {
    echo "Unknown demo acceptance gate: $gate" >&2
    exit 2
  }
  selected["$gate"]=1
}

if [ -n "${DEMO_SUITE:-}" ]; then
  if [ -n "${DEMO_GROUPS:-}" ] || [ "$#" -ne 0 ]; then
    echo "DEMO_SUITE cannot be combined with DEMO_GROUPS or positional gates." >&2
    exit 2
  fi
  jq -e --arg suite "$DEMO_SUITE" 'has($suite)' "$SUITE_REGISTRY" >/dev/null || {
    echo "Unknown demo acceptance suite: $DEMO_SUITE" >&2
    exit 2
  }
  full_suite=1
  while IFS= read -r gate; do
    select_gate "$gate"
  done < <(jq -r --arg suite "$DEMO_SUITE" '.[$suite][]' "$SUITE_REGISTRY")
elif [ "$#" -eq 0 ] && [ -z "${DEMO_GROUPS:-}" ]; then
  full_suite=1
  while IFS= read -r gate; do
    select_gate "$gate"
  done < <(jq -r '.[].name' "$GATE_REGISTRY")
else
  if [ -n "${DEMO_GROUPS:-}" ]; then
    IFS=',' read -r -a env_groups <<< "$DEMO_GROUPS"
    for gate in "${env_groups[@]}"; do
      select_gate "$gate"
    done
  fi
  for gate in "$@"; do
    select_gate "$gate"
  done
fi

if [ "${DEMO_ATOMIC_GATE:-0}" != "1" ]; then
  changed=1
  while [ "$changed" -eq 1 ]; do
    changed=0
    for gate in "${!selected[@]}"; do
      while IFS= read -r dependency; do
        [ -n "$dependency" ] || continue
        gate_exists "$dependency" || {
          echo "Gate $gate requires unknown gate $dependency" >&2
          exit 2
        }
        if [ "${selected[$dependency]:-0}" != "1" ]; then
          selected["$dependency"]=1
          changed=1
        fi
      done < <(jq -r --arg gate "$gate" '.[] | select(.name == $gate) | .requires[]' "$GATE_REGISTRY")
    done
  done
fi

record_group() {
  local gate="$1"
  local status="$2"
  local detail="$3"
  gate_status["$gate"]="$status"
  printf '%s\t%s\t%s\n' "$gate" "$status" "$detail" >> "$ARTIFACT_DIR/groups.tsv"
}

mark_remaining_blocked() {
  local failed_gate="$1"
  local seen_failed=0
  local gate
  while IFS= read -r gate; do
    [ "${selected[$gate]:-0}" = "1" ] || continue
    if [ "$gate" = "$failed_gate" ]; then
      seen_failed=1
      continue
    fi
    [ "$seen_failed" -eq 1 ] || continue
    [ -z "${gate_status[$gate]:-}" ] || continue
    record_group "$gate" BLOCKED "not executed because the acceptance environment became unusable after $failed_gate"
  done < <(jq -r '.[].name' "$GATE_REGISTRY")
}

environment_is_usable() {
  local status_file="$ARTIFACT_DIR/environment-after-failure.json"
  local stderr_file="$ARTIFACT_DIR/environment-after-failure.stderr.txt"

  [ -s "$DEMO_ROOT/baseharbor.yaml" ] || return 1

  set +e
  (
    cd "$DEMO_ROOT"
    "$BAHA" status -o json >"$status_file" 2>"$stderr_file"
  )
  set -e

  [ -s "$status_file" ] || return 1
  jq -e '.state == "running"' "$status_file" >/dev/null 2>&1
}

report_and_exit() {
  local rc="$1"
  set +e
  bash "$DEMO_ROOT/scripts/report.sh" "$ARTIFACT_DIR/results.tsv"
  set -e
  exit "$rc"
}

# Keep the registry off stdin: workload exec may consume inherited input.
mapfile -t ordered_gates < <(jq -r '.[].name' "$GATE_REGISTRY")
for gate in "${ordered_gates[@]}"; do
  [ "${selected[$gate]:-0}" = "1" ] || continue
  script="$DEMO_ROOT/tests/$gate/run.sh"
  test -x "$script" || test -f "$script" || {
    echo "Demo gate script missing: $script" >&2
    exit 2
  }

  # Suite mode preserves dependency ordering. Atomic mode deliberately
  # bootstraps only the selected gate's minimal fixture instead.
  failed_dependency=""
  if [ "${DEMO_ATOMIC_GATE:-0}" != "1" ]; then
    while IFS= read -r dependency; do
      [ -n "$dependency" ] || continue
      case "${gate_status[$dependency]:-}" in
        PASS) ;;
        "")
          echo "Gate order is invalid: $gate requires $dependency before it has run" >&2
          exit 2
          ;;
        *)
          failed_dependency="$dependency"
          ;;
      esac
    done < <(jq -r --arg gate "$gate" '.[] | select(.name == $gate) | .requires[]' "$GATE_REGISTRY")
  fi

  if [ -n "$failed_dependency" ]; then
    record_group "$gate" BLOCKED "not executed because prerequisite $failed_dependency did not pass"
    continue
  fi

  printf '\n>>> demo-%s\n' "$gate"
  if [ "${DEMO_ATOMIC_GATE:-0}" = "1" ] && [ "$gate" != "guided" ] && [ "$gate" != "config-matrix" ] && [ "$gate" != "init" ] && [ "$gate" != "mcp" ] && [ "$gate" != "agent" ]; then
    bash "$DEMO_ROOT/tests/atomic-bootstrap.sh" "$gate"
  fi
  set +e
  bash "$script"
  rc=$?
  set -e

  if [ "$rc" -eq 0 ]; then
    record_group "$gate" PASS "selected acceptance gate passed"
    continue
  fi

  # A later full-destroy gate can remove the failed runtime before EXIT.
  # Preserve the original failure while its containers are still available.
  bash "$DEMO_ROOT/scripts/failure-runtime-diagnostics.sh" "$gate" || true

  if [ "$full_suite" -ne 1 ]; then
    record_group "$gate" FAIL "selected acceptance gate failed (exit $rc)"
    report_and_exit "$rc"
  fi

  if environment_is_usable; then
    record_group "$gate" FAIL "selected acceptance gate failed (exit $rc); shared runtime remains usable"
    echo "demo-$gate failed, but the shared application runtime is still running; continuing full acceptance." >&2
    continue
  fi

  record_group "$gate" ERROR "gate failed (exit $rc) and the shared acceptance runtime is no longer usable"
  mark_remaining_blocked "$gate"
  echo "demo-$gate failed and the shared acceptance runtime is not usable; aborting remaining gates." >&2
  report_and_exit 70
done

# A successful report must include every selected gate, even if execution
# unexpectedly stops without returning a failing gate.
for gate in "${ordered_gates[@]}"; do
  [ "${selected[$gate]:-0}" = "1" ] || continue
  if [ -z "${gate_status[$gate]:-}" ]; then
    record_group "$gate" ERROR "selected acceptance gate did not execute"
  fi
done

set +e
bash "$DEMO_ROOT/scripts/report.sh" "$ARTIFACT_DIR/results.tsv"
report_rc=$?
set -e
exit "$report_rc"
