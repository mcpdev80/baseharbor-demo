#!/usr/bin/env bash
set -euo pipefail

: "${DEMO_ROOT:?DEMO_ROOT is required}"
: "${ARTIFACT_DIR:?ARTIFACT_DIR is required}"
: "${BAHA:?BAHA is required}"

mkdir -p "$ARTIFACT_DIR"
RESULTS_FILE="$ARTIFACT_DIR/results.tsv"
touch "$RESULTS_FILE"

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
  "$@" > "$ARTIFACT_DIR/$name.json"
  jq -e . "$ARTIFACT_DIR/$name.json" >/dev/null
  assert_no_secret_leak "$ARTIFACT_DIR/$name.json"
}
