#!/usr/bin/env bash
set -euo pipefail
source "$DEMO_ROOT/tests/lib.sh"

section "Bash completion, shell integration and Target-aware prompt"

completion_file="$ARTIFACT_DIR/bash-completion.sh"
shell_init_file="$ARTIFACT_DIR/bash-shell-init.sh"
prompt_config_file="$ARTIFACT_DIR/prompt-config.txt"
prompt_file="$ARTIFACT_DIR/prompt.txt"
completion_probe_file="$ARTIFACT_DIR/completion-probe.txt"

"$BAHA" completion bash > "$completion_file"
grep -q '_baha_completion()' "$completion_file"
grep -q 'complete -o default -F _baha_completion baha' "$completion_file"

"$BAHA" shell-init bash > "$shell_init_file"
grep -q 'baha_target_activate()' "$shell_init_file"
grep -q '_baha_prompt_command()' "$shell_init_file"

"$BAHA" config prompt   --enable   --preset compact   --position before-path   --environment always   --show-application   --text-only > "$prompt_config_file"

(
  cd "$DEMO_ROOT"
  "$BAHA" prompt --plain > "$prompt_file"
)

grep -q "$BASEHARBOR_TARGET" "$prompt_file"
grep -q 'baseharbor-demo' "$prompt_file"

PATH="$BASEHARBOR_INSTALL_DIR:$PATH" COMPLETION_FILE="$completion_file" SHELL_INIT_FILE="$shell_init_file" bash --noprofile --norc -c '
  set -euo pipefail
  source "$COMPLETION_FILE"
  source "$SHELL_INIT_FILE"
  type _baha_completion >/dev/null
  type baha_target_activate >/dev/null
  COMP_WORDS=(baha tar)
  COMP_CWORD=1
  _baha_completion
  printf "%s\n" "${COMPREPLY[@]}"
' > "$completion_probe_file"

grep -qx 'target' "$completion_probe_file"
assert_no_secret_leak "$prompt_config_file"
assert_no_secret_leak "$prompt_file"

pass "Shell UX" "Bash completion, shell-init helpers and Target-aware prompt are usable"
