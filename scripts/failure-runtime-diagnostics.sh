#!/usr/bin/env bash
set -uo pipefail

: "${DEMO_ROOT:?DEMO_ROOT is required}"
: "${ARTIFACT_DIR:?ARTIFACT_DIR is required}"
gate="${1:?failed gate is required}"
[[ "$gate" =~ ^[a-z0-9-]+$ ]] || exit 2
runtime="${BASEHARBOR_TEST_RUNTIME:?runtime is required}"
case "$runtime" in docker|podman) ;; *) exit 2 ;; esac
output="$ARTIFACT_DIR/failure-runtime/$gate"
mkdir -p "$output"

runtime_cmd() {
  if [ "$runtime" = podman ]; then
    env -u XDG_CONFIG_HOME -u XDG_DATA_HOME podman "$@"
  else
    docker "$@"
  fi
}
redact() {
  python3 "$DEMO_ROOT/scripts/redact-runtime-diagnostics.py"
}

# These standard read-only results expose references and consequences, not env
# values. Retain the actual pending union before later cleanup removes its owner.
for command in plan status; do
  (
    cd "$DEMO_ROOT"
    timeout --signal=TERM --kill-after=3s 25s "$BAHA" app "$command" --json 2>&1
  ) | head -c 1048576 | redact >"$output/application-$command.json" || true
done

runtime_cmd ps -a --format '{{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Image}}' | redact >"$output/containers.tsv"
for id in $(runtime_cmd ps -aq 2>/dev/null); do
  name="$(runtime_cmd inspect --format '{{.Name}}' "$id" 2>/dev/null)"
  name="${name#/}"
  case "$name" in bh-*|baseharbor-*) ;; *) continue ;; esac
  safe="$(printf '%s' "$name" | tr -c 'a-zA-Z0-9_.-' '_')"
  # Inspect only readiness/network facts, never Config.Env or private mounts.
  runtime_cmd inspect --format 'state={{json .State}} networks={{json .NetworkSettings.Networks}}' "$id" 2>&1 | redact >"$output/$safe.state.txt"
  runtime_cmd logs --tail 300 "$id" 2>&1 | redact >"$output/$safe.log"
done
printf '[acceptance] preserved failure-time native diagnostics for %s\n' "$gate" >&2
