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
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/tmp/baseharbor-demo-xdg/config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-/tmp/baseharbor-demo-xdg/data}"
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
  set +e
  cd "$DEMO_ROOT"
  printf '[acceptance] cleanup: begin (exit=%s)\n' "$status" >&2
  for id in $(runtime_cmd ps -q 2>/dev/null); do
    runtime_cmd unpause "$id" >/dev/null 2>&1 || true
  done

  if [ "$status" -ne 0 ]; then
    diagnostics="$ARTIFACT_DIR/runtime-diagnostics"
    mkdir -p "$diagnostics"
    runtime_cmd ps -a --format '{{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Image}}' >"$diagnostics/containers.tsv" 2>&1 || true
    for id in $(runtime_cmd ps -aq 2>/dev/null); do
      name=$(runtime_cmd inspect --format '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##')
      [ -n "$name" ] || name="$id"
      safe_name=$(printf '%s' "$name" | tr '/: ' '___')
      runtime_cmd inspect --format '{{json .State}}' "$id" >"$diagnostics/$safe_name.state.json" 2>&1 || true
      runtime_cmd inspect --format 'image={{.Config.Image}} name={{.Name}}' "$id" >"$diagnostics/$safe_name.identity.txt" 2>&1 || true
      runtime_cmd logs --tail 300 "$id" 2>&1 \
        | sed -E 's/([Pp]assword|[Ss]ecret|[Tt]oken|[Aa]ccess[_-]?[Kk]ey)([=: ]+)[^[:space:]]+/\1\2<redacted>/g' \
        >"$diagnostics/$safe_name.log" || true
    done
    printf '[acceptance] cleanup: captured runtime diagnostics\n' >&2
  fi

  printf '[acceptance] cleanup: destroy registered BaseHarbor state\n' >&2
  if ! timeout --signal=TERM --kill-after=5s 90s "$BAHA" destroy --all --yes >/dev/null 2>&1; then
    printf '[acceptance] cleanup: full destroy did not finish cleanly; falling back to app cleanup\n' >&2
    timeout --signal=TERM --kill-after=5s 45s "$BAHA" app destroy --yes >/dev/null 2>&1 || true
    cd "$DEMO_ROOT/companion-app"
    timeout --signal=TERM --kill-after=5s 45s "$BAHA" app destroy --yes >/dev/null 2>&1 || true
    rm -rf "$XDG_CONFIG_HOME/baseharbor" "$XDG_DATA_HOME/baseharbor" "$XDG_DATA_HOME/baseharbor-recovery"
  fi
  printf '[acceptance] cleanup: complete\n' >&2
  exit "$status"
}
trap cleanup EXIT


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
