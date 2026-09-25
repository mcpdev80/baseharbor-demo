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
if [ ! -s "$DEMO_ROOT/companion-app/baseharbor.yaml" ]; then
  echo "Companion source manifest was removed by full destroy: $DEMO_ROOT/companion-app/baseharbor.yaml" >&2
  exit 1
fi

if "$BASEHARBOR_TEST_RUNTIME" ps -a --format '{{.Names}}' | grep -Eiq '^baseharbor-|baseharbor-demo'; then
  echo "BaseHarbor-managed/application containers remain after full destroy" >&2
  "$BASEHARBOR_TEST_RUNTIME" ps -a --format '{{.Names}}' >&2
  exit 1
fi

pass "Full destroy" "all registered deployments and BaseHarbor XDG state removed while source repositories remain"
