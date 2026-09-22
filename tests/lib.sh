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
