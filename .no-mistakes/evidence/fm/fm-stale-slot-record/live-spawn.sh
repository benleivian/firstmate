#!/bin/bash
set -eu
ROOT=$PWD
L=$ROOT/.test-tmp/live
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS TMUX TMUX_PANE
export FM_HOME=$L/home FM_BACKEND=tmux
SOCKET=$ROOT/s
trap 'tmux -S "$SOCKET" kill-server 2>/dev/null || true' EXIT
tmux -S "$SOCKET" -f /dev/null new-session -d -s lab -x 100 -y 30 -c "$L"
export TMUX="$SOCKET,$(tmux -S "$SOCKET" display-message -p '#{pid}'),0"
WT=$(git -C "$L/project" worktree list --porcelain | awk '/^worktree .*\.treehouse/{print substr($0,10)}')
mkdir -p "$L/project/.ddev" "$WT/.ddev" "$FM_HOME/data/new-owner"
printf 'name: fixture-primary\n' > "$L/project/.ddev/config.yaml"
git -C "$L/project" add .ddev/config.yaml
git -C "$L/project" -c commit.gpgsign=false -c user.name=Test -c user.email=test@example.invalid commit -qm ddev
# Origin-less pool starts as-is; configure both committed copies explicitly.
git -C "$WT" reset --hard "$(git -C "$L/project" rev-parse HEAD)"
printf '.ddev/config.local.yaml\n' >> "$L/project/.git/info/exclude"
printf 'name: fixture-slot-only\n' > "$WT/.ddev/config.local.yaml"
printf 'ddev_name=fixture-slot-only\n' >> "$FM_HOME/state/parked.meta"
cat > "$FM_HOME/data/new-owner/brief.md" <<'EOF'
# Task
## Captain's intent
Validate disposable launch. Do not execute tools or modify any files. Reply READY and stop.
## Firstmate spec
This is a disposable launch check. Do not perform project work.
EOF
echo 'SCENARIO: launch into slot still recorded by parked task'
bin/fm-spawn.sh new-owner "$L/project" --scout --harness codex
echo 'Published owner record:'
cat "$FM_HOME/state/new-owner.meta"
echo 'Preserved parked record:'
cat "$FM_HOME/state/parked.meta"
tmux -S "$SOCKET" list-panes -a -F '#{session_name}:#{window_name} #{pane_current_command} #{pane_current_path}'
tmux -S "$SOCKET" capture-pane -p -t firstmate:fm-new-owner || true
