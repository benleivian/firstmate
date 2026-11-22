#!/bin/bash
set -eu
LAB="$PWD/.l"
EVIDENCE=~/.no-mistakes/evidence/01M82NHW5MMJN064FSKB1M5FXN
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/tmux"
cleanup() {
  local status=$?
  if [ -S "$LAB/tmux/tmux-$(id -u)/fm-lab" ]; then
    TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server || status=1
  fi
  rm -rf "$LAB"
  exit "$status"
}
trap cleanup EXIT
export TMUX_TMPDIR="$LAB/tmux"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE tmux -L fm-lab new-session -d -s primary -n codex -x 120 -y 40 -c "$PWD" -e FM_HOME="$LAB" codex
sleep 5
tmux -L fm-lab capture-pane -p -t primary:codex > "$EVIDENCE/codex-primary-pane.txt"
if grep -q 'Update available' "$EVIDENCE/codex-primary-pane.txt"; then
  tmux -L fm-lab send-keys -t primary:codex Down Enter
  sleep 5
  tmux -L fm-lab capture-pane -p -t primary:codex > "$EVIDENCE/codex-primary-pane.txt"
fi
SOCKET=$(tmux -L fm-lab display-message -p -t primary:codex '#{socket_path}')
# TMUX routes the production adapter to exactly this owned server.
TMUX="$SOCKET,0,0" FM_HOME="$LAB" bash -c '. bin/fm-backend.sh; fm_backend_source tmux; fm_backend_agent_state tmux primary:codex' > "$EVIDENCE/codex-liveness.txt"
[ "$(cat "$EVIDENCE/codex-liveness.txt")" = alive ]
tmux -L fm-lab new-window -t primary -n bare -c "$LAB" /bin/sh
sleep 1
TMUX="$SOCKET,0,0" FM_HOME="$LAB" bash -c '. bin/fm-backend.sh; fm_backend_source tmux; fm_backend_agent_state tmux primary:bare' > "$EVIDENCE/shell-liveness.txt"
[ "$(cat "$EVIDENCE/shell-liveness.txt")" = dead ]
TMUX="$SOCKET,0,0" FM_HOME="$LAB" bash -c '. bin/fm-backend.sh; fm_backend_source tmux; fm_backend_agent_state tmux primary:absent' > "$EVIDENCE/absent-liveness.txt"
[ "$(cat "$EVIDENCE/absent-liveness.txt")" = missing ]
