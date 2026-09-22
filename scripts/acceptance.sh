#!/usr/bin/env bash
set -euo pipefail

DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEMO_ROOT
export ARTIFACT_DIR="${ARTIFACT_DIR:-$DEMO_ROOT/artifacts}"
export BASEHARBOR_INSTALL_DIR="${BASEHARBOR_INSTALL_DIR:-$DEMO_ROOT/.tools/bin}"
GATE_REGISTRY="$DEMO_ROOT/tests/gates.json"

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

if [ -n "${BASEHARBOR_SOURCE_REF:-}" ]; then
  export BASEHARBOR_RUNTIME_IMAGE=baseharbor-runtime:demo-candidate
fi
bash "$DEMO_ROOT/scripts/install-baseharbor.sh"
export BAHA="$BASEHARBOR_INSTALL_DIR/baha"
export BASEHARBOR_STATE_DIR="${BASEHARBOR_STATE_DIR:-/tmp/baseharbor-demo-platform-state}"
export BASEHARBOR_TEST_RUNTIME="${BASEHARBOR_TEST_RUNTIME:-docker}"
command -v "$BASEHARBOR_TEST_RUNTIME" >/dev/null 2>&1

cleanup() {
  status=$?
  set +e
  cd "$DEMO_ROOT"
  "$BAHA" app destroy --yes >/dev/null 2>&1 || true
  cd "$DEMO_ROOT/companion-app"
  "$BAHA" app destroy --yes >/dev/null 2>&1 || true
  "$BASEHARBOR_TEST_RUNTIME" ps -q | xargs -r "$BASEHARBOR_TEST_RUNTIME" unpause >/dev/null 2>&1
  exit "$status"
}
trap cleanup EXIT

rm -rf "$BASEHARBOR_STATE_DIR"

declare -A selected=()

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

if [ "$#" -eq 0 ] && [ -z "${DEMO_GROUPS:-}" ]; then
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

while IFS= read -r gate; do
  [ "${selected[$gate]:-0}" = "1" ] || continue
  script="$DEMO_ROOT/tests/$gate/run.sh"
  test -x "$script" || test -f "$script" || {
    echo "Demo gate script missing: $script" >&2
    exit 2
  }

  printf '\n>>> demo-%s\n' "$gate"
  if bash "$script"; then
    printf '%s\tPASS\tselected acceptance gate passed\n' "$gate" >> "$ARTIFACT_DIR/groups.tsv"
  else
    rc=$?
    printf '%s\tFAIL\tselected acceptance gate failed\n' "$gate" >> "$ARTIFACT_DIR/groups.tsv"
    bash "$DEMO_ROOT/scripts/report.sh" "$ARTIFACT_DIR/results.tsv"
    exit "$rc"
  fi
done < <(jq -r '.[].name' "$GATE_REGISTRY")

bash "$DEMO_ROOT/scripts/report.sh" "$ARTIFACT_DIR/results.tsv"
trap - EXIT
cleanup
