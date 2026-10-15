#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=~/.no-mistakes/evidence/01M50Y9G0NHGXYXX0A2ETKE167
export TMPDIR="$ROOT/.test-tmp" FM_HERDR_LAB_STATE_DIR="$ROOT/.test-tmp/lab-state"
export FM_HOME="$ROOT/.test-tmp/home"
mkdir -p "$FM_HOME"
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH
HELPER="$ROOT/bin/fm-herdr-lab.sh"
export HERDR_SESSION=$("$HELPER" name converge)
cleanup() { local rc=$?; "$HELPER" teardown "$HERDR_SESSION" || rc=1; exit "$rc"; }
"$HELPER" provision "$HERDR_SESSION"
trap cleanup EXIT
lab() { "$HELPER" run "$HERDR_SESSION" "$@"; }
# Only route the real transport to the safety helper; responses are unmodified.
herdr() { lab "$@"; }
setup_adapter() {
  . "$1"
  FM_BACKEND_HERDR_ROOT=$ROOT
  FM_ROOT=$ROOT
  fm_backend_herdr_cli() {
    local session=$1 out ws tab
    shift
    [ "$session" = "$HERDR_SESSION" ] || return 90
    out=$(lab "$@") || return
    if [ "${1:-} ${2:-}" = 'workspace create' ]; then
      ws=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id')
      tab=$(printf '%s' "$out" | jq -r '.result.tab.tab_id')
      # Let the actual shell send its cwd update before pruning.
      sleep 1
      if [ "${MODE:-auto}" = renamed ]; then lab tab rename "$tab" notes >/dev/null; fi
      lab tab list --workspace "$ws" >> "$EVIDENCE/relabel-observed.jsonl"
    fi
    printf '%s\n' "$out"
  }
}
lab status --json
lab workspace create --cwd "$ROOT" --label anchor > "$EVIDENCE/anchor.json"
setup_adapter "$ROOT/bin/backends/.test-before.sh"
MODE=auto
if fm_backend_herdr_projection_create_task "$ROOT" before fm-before; then
  echo 'ERROR: baseline unexpectedly converged'; exit 1
fi
lab tab list --workspace "$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID"
[ "$(lab tab list --workspace "$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID" | jq '.result.tabs | length')" = 2 ]
echo 'BASELINE: automatic cwd rename leaves two tabs and reproduces convergence failure.'
setup_adapter "$ROOT/bin/backends/herdr.sh"
for i in 1 2 3 4 5; do
  fm_backend_herdr_projection_create_task "$ROOT" "fixed-$i" "fm-fixed-$i"
  tabs=$(lab tab list --workspace "$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID")
  panes=$(lab pane list --workspace "$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID")
  printf '%s\n%s\n' "$tabs" "$panes"
  printf '%s' "$tabs" | jq -e --arg id "$FM_BACKEND_HERDR_PROJECTION_TAB_ID" '(.result.tabs | length) == 1 and .result.tabs[0].tab_id == $id' >/dev/null
  printf '%s' "$panes" | jq -e --arg id "$FM_BACKEND_HERDR_PROJECTION_PANE_ID" '(.result.panes | length) == 1 and .result.panes[0].pane_id == $id' >/dev/null
  echo "FIXED: delayed projection $i converged on first attempt to one task tab and pane."
done
MODE=renamed
if fm_backend_herdr_projection_create_task "$ROOT" protected fm-protected; then
  echo 'ERROR: human-renamed tab was removed'; exit 1
fi
tabs=$(lab tab list --workspace "$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID")
printf '%s\n' "$tabs"
printf '%s' "$tabs" | jq -e --arg id "$FM_BACKEND_HERDR_PROJECTION_SEEDED_TAB_ID" '(.result.tabs | length) == 2 and any(.result.tabs[]; .tab_id == $id and .label == "notes")' >/dev/null
echo 'GUARD: human-renamed notes tab survives; ambiguous projection correctly refuses.'
