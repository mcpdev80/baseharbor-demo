#!/usr/bin/env bash
set -euo pipefail

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/artifacts"

cat >"$tmp/bin/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "container" ] && [ "$2" = "exists" ] && [ "$3" = "bh-demo-podman-demo-dev-demo-app" ]; then
  exit 0
fi
if [ "$1" = "ps" ]; then
  exit 0
fi
exit 1
EOF
chmod +x "$tmp/bin/podman"

export PATH="$tmp/bin:$PATH"
export DEMO_ROOT="${DEMO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export ARTIFACT_DIR="$tmp/artifacts"
export BAHA="${BAHA:-true}"
export BASEHARBOR_TEST_RUNTIME=podman

source "$DEMO_ROOT/tests/lib.sh"

got="$(container_id_for_service demo-app bh-demo-podman-demo-dev)"
test "$got" = "bh-demo-podman-demo-dev-demo-app"

printf 'PASS  Podman deterministic workload lookup\n'
