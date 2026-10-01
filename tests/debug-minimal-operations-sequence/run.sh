#!/usr/bin/env bash
set -euo pipefail

: "${BASEHARBOR_SOURCE_REF:?BASEHARBOR_SOURCE_REF is required}"
: "${BASEHARBOR_TEST_RUNTIME:?BASEHARBOR_TEST_RUNTIME is required}"
: "${ARTIFACT_DIR:?ARTIFACT_DIR is required}"
: "${DEMO_ROOT:?DEMO_ROOT is required}"

export BASEHARBOR_INSTALL_DIR="${BASEHARBOR_INSTALL_DIR:-$DEMO_ROOT/.tools/bin}"
export BASEHARBOR_RUNTIME_IMAGE="${BASEHARBOR_RUNTIME_IMAGE:-localhost/baseharbor-runtime:demo-candidate-${BASEHARBOR_SOURCE_REF}}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/tmp/baseharbor-debug-pgexec/config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-/tmp/baseharbor-debug-pgexec/data}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/baseharbor-debug-pgexec/cache}"
export BASEHARBOR_TARGET="${BASEHARBOR_TARGET:-debug-pgexec-${BASEHARBOR_TEST_RUNTIME}}"
if [ "$BASEHARBOR_TEST_RUNTIME" = "podman" ]; then
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
fi

rm -rf "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$ARTIFACT_DIR" "$DEMO_ROOT/.baseharbor" "$DEMO_ROOT/baseharbor.yaml"
mkdir -p "$ARTIFACT_DIR"

bash "$DEMO_ROOT/scripts/install-baseharbor.sh" >"$ARTIFACT_DIR/install.txt" 2>&1
BAHA="$BASEHARBOR_INSTALL_DIR/baha"
export BAHA

"$BAHA" target create "$BASEHARBOR_TARGET" --provider "$BASEHARBOR_TEST_RUNTIME" --access "local-$BASEHARBOR_TEST_RUNTIME" --reference local --scope default --default >/dev/null

cleanup() {
  set +e
  timeout 60s "$BAHA" destroy --all --yes >/dev/null 2>&1 || true
}
trap cleanup EXIT

(
  cd "$DEMO_ROOT"
  cat > pgexec-compose.yaml <<'EOF'
services:
  pgexec-app:
    image: docker.io/library/alpine:3.24
    command: ["sh", "-ec", "while true; do sleep 3600; done"]
EOF
  "$BAHA" app init demo --environment dev --sql --workload-compose pgexec-compose.yaml --workload-service pgexec-app
  "$BAHA" app init --tls local --yes
  timeout 300s "$BAHA" --verbose up --yes >"$ARTIFACT_DIR/up.txt" 2>&1
  timeout 120s "$BAHA" app doctor >"$ARTIFACT_DIR/doctor.txt" 2>&1 || true
)
grep -q 'postgres/default ownership' "$ARTIFACT_DIR/doctor.txt"
grep -q 'postgres shared isolation' "$ARTIFACT_DIR/doctor.txt"

target_slug="${BASEHARBOR_TARGET//./-}"
shared_project="bh-${target_slug}-shared"
unit="${shared_project}-shared-postgres-dev.service"
container="${shared_project}-shared-postgres-dev"

systemctl --user status "$unit" --no-pager -l >"$ARTIFACT_DIR/unit-status-before.txt" 2>&1
podman_real() { env -u XDG_CONFIG_HOME -u XDG_DATA_HOME podman "$@"; }
podman_real inspect "$container" >"$ARTIFACT_DIR/container-inspect-before.json"

set +e
podman_real exec "$container" id >"$ARTIFACT_DIR/exec-default.txt" 2>"$ARTIFACT_DIR/exec-default.err"
default_rc=$?
set -e
printf '%s\n' "$default_rc" >"$ARTIFACT_DIR/exec-default.rc"

podman_real exec --user 0 "$container" sh -ec 'id; echo ---passwd---; cat /etc/passwd; echo ---psql---; command -v psql || true' >"$ARTIFACT_DIR/exec-root.txt" 2>"$ARTIFACT_DIR/exec-root.err"

systemctl --user stop "$unit" >/dev/null 2>&1 || true
if systemctl --user is-active --quiet "$unit"; then
  echo "shared PostgreSQL unit still active after stop" >&2
  exit 1
fi

(
  cd "$DEMO_ROOT"
  timeout 240s "$BAHA" app apply >"$ARTIFACT_DIR/reconcile-repair.txt" 2>&1
)
systemctl --user status "$unit" --no-pager -l >"$ARTIFACT_DIR/unit-status-after.txt" 2>&1
podman_real inspect "$container" >"$ARTIFACT_DIR/container-inspect-after.json"

set +e
podman_real exec "$container" id >"$ARTIFACT_DIR/exec-default-after.txt" 2>"$ARTIFACT_DIR/exec-default-after.err"
after_rc=$?
set -e
printf '%s\n' "$after_rc" >"$ARTIFACT_DIR/exec-default-after.rc"

podman_real exec --user 0 "$container" sh -ec 'id; echo ---passwd---; cat /etc/passwd; echo ---psql---; command -v psql || true' >"$ARTIFACT_DIR/exec-root-after.txt" 2>"$ARTIFACT_DIR/exec-root-after.err"

printf 'PASS  Podman shared PostgreSQL exec probe\n'
