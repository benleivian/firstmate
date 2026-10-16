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
mkdir -p "$L/elsewhere" "$FM_HOME/data/conflict"
cp "$FM_HOME/data/new-owner/brief.md" "$FM_HOME/data/conflict/brief.md"
sed "s|worktree=.*|worktree=$L/elsewhere|" "$FM_HOME/state/parked.meta" > "$L/parked.new"
mv "$L/parked.new" "$FM_HOME/state/parked.meta"
rm "$FM_HOME/state/new-owner.meta"
echo 'SCENARIO: same DDEV name recorded for another directory must refuse'
set +e
bin/fm-spawn.sh conflict "$L/project" --scout --harness codex
rc=$?
set -e
echo "spawn exit=$rc"
test "$rc" -ne 0
test ! -f "$FM_HOME/state/conflict.meta"
test -f "$FM_HOME/state/parked.meta"
echo 'No conflicting task published; parked record preserved.'
