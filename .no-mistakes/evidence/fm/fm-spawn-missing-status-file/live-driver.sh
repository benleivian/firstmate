#!/usr/bin/env bash
set -eu
ROOT=$PWD
D=$ROOT/.test-status-lab/final
E=~/.no-mistakes/evidence/01M538ASFP2524EWKK3ZMXWSSQ
export FM_HERDR_LAB_STATE_DIR=$D/herdr
export HERDR_SESSION=fm-lab-status-final
export REAL_PATH=$PATH REAL_HERDR=$(command -v herdr) LAB_HELPER=$ROOT/bin/fm-herdr-lab.sh
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_SOCKET_PATH HERDR_ENV
export FM_HOME=$D/home
bin/fm-lab-home.sh create "$FM_HOME"
mkdir -p "$D/wrappers" "$D/project"
printf 'max_trees = 4\nroot = "./"\n' > "$D/project/treehouse.toml"
cat > "$D/wrappers/herdr" <<'WRAP'
#!/usr/bin/env bash
set -eu
args=("$@")
n=${#args[@]}
if [ "$n" -ge 2 ] && [ "${args[n-2]}" = --session ] && [ "${args[n-1]}" = "$HERDR_SESSION" ]; then unset 'args[n-1]' 'args[n-2]'; fi
if [ "${args[0]}" = --version ]; then exec "$REAL_HERDR" --version --session "$HERDR_SESSION"; fi
exec env PATH="$REAL_PATH" "$LAB_HELPER" run "$HERDR_SESSION" "${args[@]}"
WRAP
chmod +x "$D/wrappers/herdr"
"$LAB_HELPER" provision "$HERDR_SESSION"
cleanup() { env PATH="$REAL_PATH" "$LAB_HELPER" teardown "$HERDR_SESSION"; echo "lab teardown exit=$?; default-session tripwire unchanged"; }
trap cleanup EXIT
export PATH=$D/wrappers:$PATH
export FM_SPAWN_NO_GUARD=1
git -C "$D/project" init -q
printf 'status lab\n' > "$D/project/README.md"
git -C "$D/project" add README.md treehouse.toml
git -C "$D/project" -c user.name=Test -c user.email=test@example.invalid commit -qm initial
git clone -q --bare "$D/project" "$D/origin.git"
git -C "$D/project" remote add origin "$D/origin.git"
cat > "$D/worker.zsh" <<'WORK'
setopt NO_CLOBBER
unsetopt APPEND_CREATE
[[ -f "$1" ]] || { print 'MISSING AT WORKER START'; exit 4; }
print 'status existed at worker start'
print started > "$2.started"
while [[ ! -e "$2" ]]; do sleep 0.1; done
print 'working [at=1]: real zsh worker reported' >> "$1" || exit 5
print 'append succeeded'
WORK
# Independently reproduce the originally reported shell failure.
if zsh -f -o noclobber -c 'print report >> "$1"' _ "$D/absent.status"; then exit 7; else echo 'BASELINE: zsh refuses append to absent status'; fi
for id in fresh kept invalid; do
  bin/fm-brief.sh "$id" project --scout --herdr-lab >/dev/null
  python3 - "$FM_HOME/data/$id/brief.md" <<'PY'
import sys
p=sys.argv[1]
s=open(p).read().replace('{TASK}', 'Validate status reporting in a disposable lab.').replace('{FIRSTMATE_SPEC}', 'Run the supplied bounded shell reporting probe only.')
open(p,'w').write(s)
PY
  status=$FM_HOME/state/$id.status
  if [ "$id" = kept ]; then printf 'failed [at=1]: earlier report\n' > "$status"; fi
  if [ "$id" = invalid ]; then mkdir "$status"; fi
  set +e
  bin/fm-spawn.sh "$id" "$D/project" "zsh -f '$D/worker.zsh' '$status' '$D/$id.go'" --scout --backend herdr > "$E/$id-spawn.log" 2>&1
  rc=$?
  set -e
  cat "$E/$id-spawn.log"
  echo "$id spawn exit=$rc"
  if [ "$id" = invalid ]; then [ "$rc" -ne 0 ]; [ ! -e "$D/$id.go.started" ]; echo "unusable status path refused; worker never started"; continue; fi
  [ "$rc" = 0 ]
  if [ "$id" = fresh ]; then
    [ -f "$status" ] && [ ! -s "$status" ]
    bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_signal_seen_current "$2/state" "$3"' _ "$ROOT" "$FM_HOME" "$status"
    echo 'fresh empty status is already seen (no creation wake)'
  else
    [ "$(cat "$status")" = 'failed [at=1]: earlier report' ]
    echo 'earlier report preserved byte-for-byte'
  fi
  touch "$D/$id.go"
  for i in $(seq 1 50); do grep -q 'real zsh worker reported' "$status" && break; sleep 0.1; done
  grep -q 'real zsh worker reported' "$status"
  if bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_signal_seen_current "$2/state" "$3"' _ "$ROOT" "$FM_HOME" "$status"; then exit 8; fi
  echo 'worker append remains unread for supervisor'
  cat "$status"
  pane=$(sed -n 's/^window=//p' "$FM_HOME/state/$id.meta")
  "$LAB_HELPER" run "$HERDR_SESSION" pane read "${pane#*:}" --source recent --lines 200 > "$E/$id-pane.log"
done
