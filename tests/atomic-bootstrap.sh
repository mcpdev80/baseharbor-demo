#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

gate="${1:?gate is required}"
registry="$DEMO_ROOT/tests/gate-resources.json"
test -s "$registry"
jq -e --arg gate "$gate" 'has($gate) and .[$gate].class == "runtime"' "$registry" >/dev/null || exit 0
capabilities="$(jq -r --arg gate "$gate" '.[$gate].guided_selection // ""' "$registry")"
management_ui="$(jq -r --arg gate "$gate" '.[$gate].management_ui // "none"' "$registry")"

clean_generated_state
rm -rf "$XDG_CONFIG_HOME/baseharbor" "$XDG_DATA_HOME/baseharbor" "$XDG_DATA_HOME/baseharbor-recovery"
"$BAHA" target create "$BASEHARBOR_TARGET"   --provider "$BASEHARBOR_TEST_RUNTIME"   --access "local-$BASEHARBOR_TEST_RUNTIME"   --reference local   --scope default   --default >/dev/null

BASEHARBOR_GUIDED_CAPABILITIES="$capabilities" BASEHARBOR_GUIDED_MANAGEMENT_UI="$management_ui" python3 "$DEMO_ROOT/tests/guided/drive.py"
