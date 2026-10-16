#!/bin/bash
set -eu
ROOT=$PWD
L=$ROOT/.test-tmp/live
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS TMUX TMUX_PANE
export FM_HOME=$L/home FM_BACKEND=tmux
bin/fm-lab-home.sh create "$FM_HOME"
bin/fm-lab-home.sh create "$L/other"
SOCKET=$ROOT/s
trap 'tmux -S "$SOCKET" kill-server 2>/dev/null || true' EXIT
tmux -S "$SOCKET" -f /dev/null new-session -d -s lab -x 100 -y 30 -c "$L"
export TMUX="$SOCKET,$(tmux -S "$SOCKET" display-message -p '#{pid}'),0"
WT=$(git -C "$L/project" worktree list --porcelain | awk '/^worktree .*\.treehouse/{print substr($0,10)}')
CLAIM=${WT%/*}/.fm-slot-owner
printf '%s\n' "- mate - fixture (home: $L/other; scope: test; projects: project; added 2026-01-01)" > "$FM_HOME/data/secondmates.md"
for mode in different empty missing; do
  for home in "$FM_HOME" "$L/other"; do
    printf 'window=lab:fm-same\nendpoint_task_id=same\nworktree=%s\nproject=%s\nkind=scout\n' "$WT" "$L/project" > "$home/state/same.meta"
  done
  case $mode in different) owner=$L/other;; empty) owner=;; missing) owner=$L/missing;; esac
  printf 'task=same\nhome=%s\n' "$owner" > "$CLAIM"
  echo "SCENARIO: claim home $mode must refuse even with --force"
  if bin/fm-teardown.sh same --force; then exit 1; fi
  test -f "$FM_HOME/state/same.meta" && test -f "$L/other/state/same.meta"
  test -f "$WT/treehouse.toml"
  echo 'Both records and pool copy preserved.'
done
rm "$FM_HOME/state/same.meta" "$L/other/state/same.meta"
for id in current parked; do
  printf 'window=lab:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nkind=scout\n' "$id" "$id" "$WT" "$L/project" > "$FM_HOME/state/$id.meta"
done
ln -s home "$L/home-alias"
printf 'task=current\nhome=%s\n' "$L/home-alias" > "$CLAIM"
echo 'SCENARIO: current owner cleans up while parked record remains (canonical home alias)'
bin/fm-teardown.sh current --force
test ! -f "$FM_HOME/state/current.meta"
test -f "$FM_HOME/state/parked.meta"
echo 'Current record removed; parked record preserved.'
(cd "$L/project" && treehouse status)
