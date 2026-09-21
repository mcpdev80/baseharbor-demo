#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Workload security"
tmp="$(mktemp)"
cp "$DEMO_ROOT/compose.yaml" "$tmp"
trap 'cp "$tmp" "$DEMO_ROOT/compose.yaml"; rm -f "$tmp"' EXIT

python3 - "$DEMO_ROOT/compose.yaml" <<'PY'
from pathlib import Path
p = Path(__import__("sys").argv[1])
s = p.read_text()
s = s.replace("    restart: unless-stopped\n\n  postgres:", "    restart: unless-stopped\n    privileged: true\n\n  postgres:", 1)
p.write_text(s)
PY

set +e
(
  cd "$DEMO_ROOT"
  "$BAHA" app preflight
) >"$ARTIFACT_DIR/security-privileged.txt" 2>&1
rc=$?
set -e
test "$rc" -ne 0
pass "Workload Security" "privileged workload denied before mutation"

cp "$tmp" "$DEMO_ROOT/compose.yaml"
trap - EXIT
rm -f "$tmp"
