#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Full BaseHarbor installation destroy"

test -s "$DEMO_ROOT/baseharbor.yaml"

"$BAHA" app list --all-targets | tee "$ARTIFACT_DIR/full-destroy-before.txt"
grep -q 'baseharbor-demo' "$ARTIFACT_DIR/full-destroy-before.txt"

"$BAHA" destroy --all --yes | tee "$ARTIFACT_DIR/full-destroy.txt"

grep -q '^Cleanup report' "$ARTIFACT_DIR/full-destroy.txt"
grep -q 'REMOVED' "$ARTIFACT_DIR/full-destroy.txt"

"$BAHA" app list --all-targets | tee "$ARTIFACT_DIR/full-destroy-after.txt"
grep -q '^No deployments registered\.$' "$ARTIFACT_DIR/full-destroy-after.txt"

test ! -e "$XDG_CONFIG_HOME/baseharbor"
test ! -e "$XDG_DATA_HOME/baseharbor"
test -s "$DEMO_ROOT/baseharbor.yaml"
test -s "$DEMO_ROOT/companion-app/baseharbor.yaml"

if "$BASEHARBOR_TEST_RUNTIME" ps -a --format '{{.Names}}' | grep -Eiq '^baseharbor-|baseharbor-demo'; then
  echo "BaseHarbor-managed/application containers remain after full destroy" >&2
  "$BASEHARBOR_TEST_RUNTIME" ps -a --format '{{.Names}}' >&2
  exit 1
fi

pass "Full destroy" "all registered deployments and BaseHarbor XDG state removed while source repositories remain"
