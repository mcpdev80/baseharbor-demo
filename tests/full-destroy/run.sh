#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Full BaseHarbor installation destroy"

test -s "$DEMO_ROOT/baseharbor.yaml"

"$BAHA" app list --all-targets | tee "$ARTIFACT_DIR/full-destroy-before.txt"
grep -q 'demo' "$ARTIFACT_DIR/full-destroy-before.txt"

run_consented "$BAHA" destroy --all --yes | tee "$ARTIFACT_DIR/full-destroy.txt"

jq -e '.destroyed == true and any(.results[]; .status == "REMOVED")' "$ARTIFACT_DIR/full-destroy.txt" >/dev/null

"$BAHA" app list --all-targets | tee "$ARTIFACT_DIR/full-destroy-after.txt"
grep -q '^No deployments registered\.$' "$ARTIFACT_DIR/full-destroy-after.txt"

if [ -e "$XDG_CONFIG_HOME/baseharbor" ]; then
  echo "BaseHarbor config state remains after full destroy: $XDG_CONFIG_HOME/baseharbor" >&2
  find "$XDG_CONFIG_HOME/baseharbor" -maxdepth 3 -print >&2 || true
  exit 1
fi
if [ -e "$XDG_DATA_HOME/baseharbor" ]; then
  echo "BaseHarbor data state remains after full destroy: $XDG_DATA_HOME/baseharbor" >&2
  find "$XDG_DATA_HOME/baseharbor" -maxdepth 4 -print >&2 || true
  exit 1
fi
if [ ! -s "$DEMO_ROOT/baseharbor.yaml" ]; then
  echo "Primary source manifest was removed by full destroy: $DEMO_ROOT/baseharbor.yaml" >&2
  exit 1
fi

target_container_prefix="bh-${BASEHARBOR_TARGET}-"
is_target_container_name() {
  case "$1" in
    "${target_container_prefix}"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Regression: persistent shared infrastructure and another Target's project
# namespace are not application leftovers for this full-destroy fixture.
if is_target_container_name "baseharbor-pre-release-registry" \
  || is_target_container_name "bh-unrelated-target-demo-app" \
  || ! is_target_container_name "${target_container_prefix}demo-app"; then
  echo "Full-destroy container scope regression: target prefix is not exact" >&2
  exit 1
fi

remaining_target_containers=()
while IFS= read -r container_name; do
  if is_target_container_name "$container_name"; then
    remaining_target_containers+=("$container_name")
  fi
done < <("$BASEHARBOR_TEST_RUNTIME" ps -a --format '{{.Names}}')

if ((${#remaining_target_containers[@]} > 0)); then
  echo "BaseHarbor-managed/application containers remain after full destroy" >&2
  printf '%s\n' "${remaining_target_containers[@]}" >&2
  exit 1
fi

pass "Full destroy" "all registered deployments and BaseHarbor XDG state removed while source repositories remain"
