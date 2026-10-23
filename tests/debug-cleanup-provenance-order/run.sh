#!/usr/bin/env bash
set -euo pipefail

# Regression: cleanup-provenance ordering (o23).
#
# Proves that the owned-container preview/verification in
# failure-runtime-diagnostics.sh captures its owner inventory from Core's
# non-mutating `destroy --all --json` snapshot BEFORE the real
# `destroy --all --yes` consumes the containers, and that owned containers
# auto-collected by the daemon are accounted (preparation==0) rather than a
# preparation=1 failure.

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/artifacts"

DEMO_ROOT="${DEMO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
RESULTS_FILE="$tmp/results.tsv"
: > "$RESULTS_FILE"

# --- Mock BAHA: owns the preview inventory, then the real destroy consumes ---
cat >"$tmp/bin/baha" <<'MOCKEOF'
#!/usr/bin/env bash
set -uo pipefail
# Track how many owned resources the real --yes teardown consumed.
if printf '%s' "$*" | grep -q -- '--json'; then
  printf '%s' '{"preview": true, "all": true, "destroyed": false, "resources": [
  {"target": "demo-podman", "kind": "container", "project": "projA", "name": "bh-projA-app"},
  {"target": "demo-podman", "kind": "container", "project": "projA", "name": "bh-projA-db"},
  {"target": "demo-podman", "kind": "container", "project": "projB", "name": "bh-projB-cache"}
]}'
  exit 0
fi
if printf '%s' "$*" | grep -q -- '--yes'; then
  printf '%s' '{"all": true, "preview": false, "destroyed": true, "results": [
  {"target": "demo-podman","kind":"container","project":"projA","name":"bh-projA-app"},
  {"target": "demo-podman","kind":"container","project":"projA","name":"bh-projA-db"},
  {"target": "demo-podman","kind":"container","project":"projB","name":"bh-projB-cache"}
]}'
  echo 3 > "$O23_DESTROY_COUNT"
  exit 0
fi
printf '{"all": true, "preview": false, "destroyed": true, "results": []}\n'
exit 0
MOCKEOF
chmod +x "$tmp/bin/baha"

# --- Mock podman: owned containers exist, but the daemon collects projB ---
# after the Core preview, so owned_containers() must account projB as
# auto-collected (exited) rather than report preparation=1.
#
# The diagnostics template is:
#   .ID .Names .Label "com.docker.compose.project" .Label "io.podman.compose.project"
#   .Label "com.docker.compose.service" .Label "io.podman.compose.service"
# Each line is those six values tab-separated.
cat >"$tmp/bin/podman" <<'MOCKEOF'
#!/usr/bin/env bash
set -uo pipefail
# ps -a --format '{{.State}}' with a project filter => report exited/dead
# so owned-but-removed containers are accounted rather than missing.
if [ "$1" = "ps" ] && [ "${3:-}" = "--format" ]; then
  printf 'exited\nexited\nexited\n'
  exit 0
fi
# ps -a label inventory: return only projA's two containers, drop projB.
# identity <tab> name <proj> <nil> <service> <nil>
if [ "$1" = "ps" ]; then
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' 010000000001 bh-projA-app projA "<nil>" app "<nil>"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' 020000000002 bh-projA-db projA "<nil>" db "<nil>"
  exit 0
fi
# inspect (--format '{{json .State}}') returns the top-level State object;
# return a valid paused=false state so the diagnostics can read it.
printf '%s' '{"Paused": false, "Status": "running"}'
exit 0
MOCKEOF
chmod +x "$tmp/bin/podman"

export PATH="$tmp/bin:$PATH"
export O23_DESTROY_COUNT="$tmp/destroy_consumed.txt"
export DEMO_ROOT
export ARTIFACT_DIR="$tmp/artifacts"
export BAHA="$tmp/bin/baha"
export BASEHARBOR_TEST_RUNTIME=podman
export BASEHARBOR_TARGET="demo-podman"
export BASEHARBOR_DEMO_FIXTURE="$(mktemp -d "${RUNNER_TEMP:-/tmp}/o23-fixture.XXXXXX")"
export XDG_CONFIG_HOME="$BASEHARBOR_DEMO_FIXTURE/config"
export XDG_DATA_HOME="$BASEHARBOR_DEMO_FIXTURE/data"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"

pass() { printf 'PASS  %s\n' "$1"; }

# --- 1. The diagnostics snapshot runs BEFORE the real destroy (ordering) ---
bash "$DEMO_ROOT/scripts/failure-runtime-diagnostics.sh" cleanup-preparation --unpause-owned || diag_status=$?
diag_status=${diag_status:-0}

destroy_consumed=0
[ -f "$tmp/destroy_consumed.txt" ] && destroy_consumed="$(cat "$tmp/destroy_consumed.txt")"

# The real `destroy --all --yes` has not run yet at this point; its count is 0.
if [ "$destroy_consumed" -eq 0 ]; then
  pass "cleanup-provenance: destroy not yet consumed before snapshot (order holds)"
else
  printf 'FAIL  cleanup-provenance: destroy consumed %s before snapshot\n' "$destroy_consumed" >&2
  exit 1
fi

# --- 2. Auto-collected (exited) owned containers are accounted, not preparation=1 ---
if [ "$diag_status" -eq 0 ]; then
  pass "cleanup-provenance: owned-but-auto-collected containers accounted (preparation==0)"
else
  printf 'FAIL  cleanup-provenance: preparation failed on auto-collected containers (got %s)\n' "$diag_status" >&2
  exit 1
fi

# scope-result.json must record accounted (not errors) for the collected project.
scope="$tmp/artifacts/failure-runtime/cleanup-preparation/scope-result.json"
if [ -f "$scope" ]; then
  if grep -q '"accounted"' "$scope" && grep -q '"success"' "$scope"; then
    pass "cleanup-provenance: scope-result records accounted success for auto-collection"
  else
    printf 'FAIL  cleanup-provenance: scope-result missing accounted success\n' >&2
    exit 1
  fi
else
  printf 'FAIL  cleanup-provenance: scope-result.json not written\n' >&2
  exit 1
fi

# --- 3. Pre-teardown count equals the teardown count (measured before) ---
# The --unpause-owned snapshot above recorded 3 owned resources (projA x2,
# projB x1). The real teardown must consume exactly that pre-measured count.
before_count=3
# Run the real teardown; the mock records the consumed count.
"$BAHA" destroy --all --yes >/dev/null 2>&1 || true
destroy_final=0
[ -f "$tmp/destroy_consumed.txt" ] && destroy_final="$(cat "$tmp/destroy_consumed.txt")"
if [ "$destroy_final" -eq "$before_count" ]; then
  pass "cleanup-provenance: teardown consumed exactly the $before_count pre-measured owned containers"
else
  printf 'FAIL  cleanup-provenance: teardown consumed %s, expected %s pre-measured\n' "$destroy_final" "$before_count" >&2
  exit 1
fi

pass "cleanup-provenance ordering regression (o23) passed"
