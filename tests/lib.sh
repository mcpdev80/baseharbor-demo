#!/usr/bin/env bash
set -euo pipefail

: "${DEMO_ROOT:?DEMO_ROOT is required}"
: "${ARTIFACT_DIR:?ARTIFACT_DIR is required}"
: "${BAHA:?BAHA is required}"

mkdir -p "$ARTIFACT_DIR"
RESULTS_FILE="$ARTIFACT_DIR/results.tsv"
touch "$RESULTS_FILE"

CONTAINER_CLI="${BASEHARBOR_TEST_RUNTIME:-}"
if [ -z "$CONTAINER_CLI" ]; then
  if command -v docker >/dev/null 2>&1; then
    CONTAINER_CLI=docker
  elif command -v podman >/dev/null 2>&1; then
    CONTAINER_CLI=podman
  else
    echo "Neither docker nor podman is available for acceptance diagnostics." >&2
    exit 1
  fi
fi
command -v "$CONTAINER_CLI" >/dev/null 2>&1
export CONTAINER_CLI

section() {
  printf '\n== %s ==\n' "$1"
}

record() {
  printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$RESULTS_FILE"
}

pass() {
  printf 'PASS  %s\n' "$1"
  record "$1" PASS "${2:-}"
}

fail() {
  printf 'FAIL  %s: %s\n' "$1" "${2:-failed}" >&2
  record "$1" FAIL "${2:-failed}"
  return 1
}

clean_generated_state() {
  rm -rf "$DEMO_ROOT/.baseharbor" "$DEMO_ROOT/baseharbor.yaml" "$DEMO_ROOT/envs/dev/baseharbor.yaml" "$DEMO_ROOT/envs/test/baseharbor.yaml" "$DEMO_ROOT/envs/prod/baseharbor.yaml"
}

assert_no_secret_leak() {
  local file="$1"
  ! grep -Fq 'acceptance-secret-value' "$file"
  ! grep -Eqi '(AWS_SECRET_ACCESS_KEY|APP_SECRET)=([^<]|$)' "$file"
}

remove_managed_service_for_reconcile() {
  local service="$1"
  local project="$2"

  if [ "$CONTAINER_CLI" = "podman" ]; then
    local expected unit
    expected="$project-$service"
    unit="$expected.service"
    systemctl --user stop "$unit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do
      if ! "$CONTAINER_CLI" container exists "$expected" >/dev/null 2>&1; then
        return 0
      fi
      sleep 1
    done
    "$CONTAINER_CLI" rm -f "$expected" >/dev/null 2>&1 || true
    return 0
  fi

  local container
  container="$(container_id_for_service "$service" "$project")"
  test -n "$container"
  "$CONTAINER_CLI" rm -f "$container" >/dev/null
}
runtime_container_cli() {
  "$CONTAINER_CLI" "$@"
}

container_id_for_service() {
  local service="$1"
  local project="${2:-}"
  local id=""

  if [ -n "$project" ]; then
    id="$(runtime_container_cli ps -q       --filter "label=com.docker.compose.project=$project"       --filter "label=com.docker.compose.service=$service" | head -n1 || true)"
  else
    id="$(runtime_container_cli ps -q       --filter "label=com.docker.compose.service=$service" | head -n1 || true)"
  fi

  if [ -z "$id" ] && [ "$CONTAINER_CLI" = "podman" ]; then
    if [ -n "$project" ]; then
      expected="$project-$service"
      if runtime_container_cli container exists "$expected" >/dev/null 2>&1; then
        id="$expected"
      fi
    fi
    if [ -z "$id" ]; then
      id="$(runtime_container_cli ps --format '{{.ID}} {{.Names}}' | awk -v s="$service" '$2 == s || $2 ~ ("(^|[-_])" s "($|[-_])") {print $1; exit}')"
    fi
  fi

  printf '%s\n' "$id"
}

run_json() {
  local name="$1"; shift
  local stdout_file="$ARTIFACT_DIR/$name.json"
  local stderr_file="$ARTIFACT_DIR/$name.stderr.txt"
  local rc

  set +e
  "$@" >"$stdout_file" 2>"$stderr_file"
  rc=$?
  set -e

  if [ "$rc" -ne 0 ]; then
    printf 'run_json %s failed with exit code %s\n' "$name" "$rc" >&2
    cat "$stderr_file" >&2 || true
    return "$rc"
  fi

  if ! jq -e . "$stdout_file" >/dev/null; then
    printf 'run_json %s produced invalid JSON\n' "$name" >&2
    cat "$stdout_file" >&2 || true
    cat "$stderr_file" >&2 || true
    return 1
  fi

  assert_no_secret_leak "$stdout_file"
}


dev_gateway_port() {
  local state port
  state="$XDG_DATA_HOME/baseharbor/targets/$BASEHARBOR_TARGET/developer-access/dev/gateway/routes.json"
  if [ ! -s "$state" ]; then
    echo "developer gateway state is missing: $state" >&2
    return 1
  fi
  port="$(jq -r '.host_port // empty' "$state")"
  if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    echo "developer gateway state contains invalid host_port: $state" >&2
    return 1
  fi
  printf '%s\n' "$port"
}

dev_gateway_url() {
  local host="$1"
  local port
  port="$(dev_gateway_port)"
  if [ "$port" = "443" ]; then
    printf 'https://%s\n' "$host"
  else
    printf 'https://%s:%s\n' "$host" "$port"
  fi
}
