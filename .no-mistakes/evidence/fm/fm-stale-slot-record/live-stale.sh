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
printf 'window=lab:fm-parked\nendpoint_task_id=parked\nworktree=%s\nproject=%s\nkind=scout\n' "$WT" "$L/project" > "$FM_HOME/state/parked.meta"
printf 'task=survivor\nhome=%s\n' "$FM_HOME" > "${WT%/*}/.fm-slot-owner"
echo sentinel > "$WT/sentinel"
echo 'SCENARIO: old record retires without touching the new owner copy'
bin/fm-teardown.sh parked --force
test ! -f "$FM_HOME/state/parked.meta"
test "$(cat "$WT/sentinel")" = sentinel
test "$(head -1 "${WT%/*}/.fm-slot-owner")" = task=survivor
echo 'Old record removed; sentinel and survivor ownership preserved.'
printf 'window=lab:fm-survivor\nendpoint_task_id=survivor\nworktree=%s\nproject=%s\nkind=scout\n' "$WT" "$L/project" > "$FM_HOME/state/survivor.meta"
printf 'home=%s\nkind=secondmate\n' "$WT" > "$FM_HOME/state/protected-home.meta"
echo 'SCENARIO: a recorded home at this path must still block the claimant'
if bin/fm-teardown.sh survivor --force; then exit 1; fi
test -f "$FM_HOME/state/survivor.meta"
test -f "$WT/sentinel"
echo 'Home collision refused; owner record and sentinel preserved.'
