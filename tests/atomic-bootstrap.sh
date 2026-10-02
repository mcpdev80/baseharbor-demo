#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

gate="${1:?gate is required}"
capabilities=""
management_ui="none"

case "$gate" in
  lifecycle|policy|connectivity|full-destroy|backup-restore)
    capabilities=""
    ;;
  data-capabilities)
    capabilities="1,2,8,9"
    ;;
  observability)
    capabilities="11,12,13"
    ;;
  identity)
    capabilities="10"
    management_ui="identity"
    ;;
  security)
    capabilities="1,2,8,10,12"
    ;;
  reconciliation)
    capabilities="1"
    ;;
  failure)
    capabilities="11"
    ;;
  *)
    exit 0
    ;;
esac

clean_generated_state
rm -rf "$XDG_CONFIG_HOME/baseharbor" "$XDG_DATA_HOME/baseharbor" "$XDG_DATA_HOME/baseharbor-recovery"
"$BAHA" target create "$BASEHARBOR_TARGET"   --provider "$BASEHARBOR_TEST_RUNTIME"   --access "local-$BASEHARBOR_TEST_RUNTIME"   --reference local   --scope default   --default >/dev/null

BASEHARBOR_GUIDED_CAPABILITIES="$capabilities" BASEHARBOR_GUIDED_MANAGEMENT_UI="$management_ui" python3 "$DEMO_ROOT/tests/guided/drive.py"
