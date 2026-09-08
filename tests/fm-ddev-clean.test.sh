#!/usr/bin/env bash
# Behavior tests for bin/fm-ddev-clean.sh's allowlist-only DDEV cleanup.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLEAN="$ROOT/bin/fm-ddev-clean.sh"
TMP_ROOT=$(fm_test_tmproot fm-ddev-clean)
HOME_DIR="$TMP_ROOT/home"
STATE="$TMP_ROOT/state"
DATA="$TMP_ROOT/data"
CONFIG="$TMP_ROOT/config"
PROJECTS_DIR="$TMP_ROOT/projects"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
DDEV_JSON="$TMP_ROOT/projects.json"
ACTION_LOG="$TMP_ROOT/actions.log"
mkdir -p "$HOME_DIR" "$STATE" "$DATA" "$CONFIG" "$PROJECTS_DIR"

cat > "$FAKEBIN/ddev" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = list ] && [ "${2:-}" = --json-output ]; then
  [ -z "${DDEV_JSON_PREFIX:-}" ] || printf '%s\n' "$DDEV_JSON_PREFIX"
  cat "$DDEV_JSON"
  exit 0
fi
printf 'ddev %s\n' "$*" >> "$ACTION_LOG"
SH
cat > "$FAKEBIN/docker" <<'SH'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$ACTION_LOG"
SH
chmod +x "$FAKEBIN/ddev" "$FAKEBIN/docker"

run_clean() {
  HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" FM_PROJECTS_OVERRIDE="$PROJECTS_DIR" \
    DDEV_JSON="$DDEV_JSON" ACTION_LOG="$ACTION_LOG" \
    DDEV_JSON_PREFIX='{"level":"info","msg":"table follows"}' PATH="$FAKEBIN:$PATH" \
    FM_DDEV_CLEAN_TIMEOUT_SECS=5 "$CLEAN" "$@"
}

write_projects() {
  cat > "$DDEV_JSON" <<EOF
{"raw":[
{"name":"smileadvantage-review-01m1ezrq","approot":"$HOME_DIR/.no-mistakes/worktrees/1289b3aed15b/01M1EZRQV0Z5EDA0JJSC3TQR4T","status":"running"},
{"name":"smileadvantage-v3-01m1ezrrsqt5fy0m87p067k9mp","approot":"$HOME_DIR/.no-mistakes/worktrees/1289b3aed15b/01M1EZRRSQT5FY0M87P067K9MP","status":"running"},
{"name":"svvy-v2-pr1208-5ed446","approot":"$HOME_DIR/.treehouse/smileadvantage-v3-5ed446/2/smileadvantage-v3","status":"running"},
{"name":"hub-test-5ed446","approot":"$HOME_DIR/.treehouse/smileadvantage-v3-5ed446/3/smileadvantage-v3","status":"running"},
{"name":"svvy-v2-pr1341-5ed446","approot":"$HOME_DIR/.treehouse/smileadvantage-v3-5ed446/4/smileadvantage-v3","status":"running"},
{"name":"acst-assessments","approot":"$HOME_DIR/Sites/acst/acst-assessments","status":"running"}
]}
EOF
}

prepare_sweep_fixture() {
  local slot
  rm -rf "$STATE"
  mkdir -p "$STATE" "$HOME_DIR/Sites/acst/acst-assessments"
  for slot in 2 3 4; do
    mkdir -p "$HOME_DIR/.treehouse/smileadvantage-v3-5ed446/$slot/smileadvantage-v3"
  done
  fm_write_meta "$STATE/live-four.meta" "worktree=$HOME_DIR/.treehouse/smileadvantage-v3-5ed446/4/smileadvantage-v3"
  write_projects
}

test_worktree_only_deletes_the_recorded_ddev_name() {
  local wt outside out
  wt="$HOME_DIR/.treehouse/project/1/task"
  outside="$TMP_ROOT/outside"
  mkdir -p "$wt/nested" "$outside"
  fm_write_meta "$STATE/task-z1.meta" "worktree=$wt" "ddev_name=inside-task-z1"
  cat > "$DDEV_JSON" <<EOF
{"raw":[{"name":"inside-task-z1","approot":"$wt/nested","status":"running"},{"name":"other-inside","approot":"$wt","status":"running"},{"name":"outside","approot":"$outside","status":"running"}]}
EOF
  : > "$ACTION_LOG"
  out=$(run_clean --worktree "$wt" --apply) || fail "worktree cleanup failed: $out"
  [ "$(cat "$ACTION_LOG")" = 'ddev delete -Oy inside-task-z1' ] \
    || fail "worktree cleanup did not use the recorded DDEV name: $(cat "$ACTION_LOG")"
  assert_contains "$out" "delete: inside" "worktree cleanup did not name its deletion"
  pass "fm-ddev-clean: worktree cleanup uses its recorded DDEV name"
}

test_fleet_cleanup_is_allowlist_only_and_safe() {
  local worker primary out
  worker="$HOME_DIR/.treehouse/svvy-v2-1faa74/1/svvy-v2"
  primary="$PROJECTS_DIR/svvy-v2"
  mkdir -p "$worker" "$primary/.ddev" "$CONFIG"
  printf 'name: svvy-v2\n' > "$primary/.ddev/config.yaml"
  printf 'operator-kept\n' > "$CONFIG/ddev-protected-names"
  fm_write_meta "$STATE/fix-z1.meta" "worktree=$worker"
  cat > "$DDEV_JSON" <<EOF
{"raw":[
{"name":"svvy-v2","approot":"$worker","status":"running"},
{"name":"operator-kept","approot":"$HOME_DIR/.treehouse/other/1/project","status":"running"},
{"name":"svvy-v2-fix-z1","approot":"$HOME_DIR/.treehouse/svvy-v2-1faa74/2/svvy-v2","status":"stopped"},
{"name":"svvy-v2-pr777","approot":"$HOME_DIR/Sites/svvy-v2","status":"running"}
]}
EOF
  : > "$ACTION_LOG"
  out=$(run_clean) || fail "fleet dry-run failed: $out"
  assert_contains "$out" "protected: svvy-v2" "unsuffixed primary name was not protected"
  assert_contains "$out" "protected: operator-kept" "protected-list name was not protected"
  assert_contains "$out" "stop-unlist: svvy-v2-fix-z1 ($HOME_DIR/.treehouse/svvy-v2-1faa74/2/svvy-v2)" "missing generated environment was not stop-unlisted"
  assert_contains "$out" "protected: svvy-v2-pr777" "outside generated environment was not ambiguous"
  assert_not_contains "$out" 'delete: svvy-v2' "fleet cleanup composed a delete for the captain's name"
  [ ! -s "$ACTION_LOG" ] || fail "dry-run invoked a mutating command: $(cat "$ACTION_LOG")"

  run_clean --apply >/dev/null || fail "fleet apply failed"
  assert_grep 'ddev stop --remove-data --omit-snapshot --unlist svvy-v2-fix-z1' "$ACTION_LOG" \
    "stale generated environment did not omit the unavailable snapshot"
  assert_not_contains "$(cat "$ACTION_LOG")" 'svvy-v2-pr777' "ambiguous environment was acted on"
  pass "fm-ddev-clean: fleet cleanup protects names and only stops safe generated environments"
}

test_sweep_apply_runs_generated_cleanup_and_host_prune() {
  local actual
  prepare_sweep_fixture
  : > "$ACTION_LOG"
  run_clean --apply >/dev/null || fail "sweep apply failed"
  assert_grep 'ddev stop --remove-data --omit-snapshot --unlist smileadvantage-review-01m1ezrq' "$ACTION_LOG" \
    "missing no-mistakes environment was not stopped with omit-snapshot"
  assert_grep 'ddev delete -Oy svvy-v2-pr1208-5ed446' "$ACTION_LOG" "generated pool environment was not deleted"
  assert_grep 'ddev delete -Oy hub-test-5ed446' "$ACTION_LOG" "style-suffixed pool environment was not deleted"
  actual=$(cat "$ACTION_LOG")
  assert_not_contains "$actual" 'svvy-v2-pr1341-5ed446' "live generated environment was selected"
  assert_grep 'docker volume prune -f' "$ACTION_LOG" "host volume prune was omitted"
  pass "fm-ddev-clean: apply keeps live copies and reclaims generated stale resources"
}

test_missing_ddev_is_a_per_task_noop_and_sweep_error() {
  local restricted out rc tool
  restricted="$TMP_ROOT/no-ddev"
  mkdir -p "$restricted" "$TMP_ROOT/missing-ddev-worktree"
  for tool in bash dirname; do
    ln -s "$(command -v "$tool")" "$restricted/$tool"
  done
  rc=0
  out=$(PATH="$restricted" "$restricted/bash" "$CLEAN" --worktree "$TMP_ROOT/missing-ddev-worktree" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "missing ddev should be a no-op for one worktree: $out"
  assert_contains "$out" 'ddev is not installed' "missing ddev did not explain the skipped worktree cleanup"
  rc=0
  out=$(PATH="$restricted" "$restricted/bash" "$CLEAN" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "missing ddev should fail a fleet sweep"
  pass "fm-ddev-clean: missing ddev is safe per task and visible for a sweep"
}

test_selection_guards_apply_to_both_modes() {
  local wt outside mode out name
  wt="$HOME_DIR/.treehouse/legacy/1/project"
  outside="$HOME_DIR/Sites/primary"
  mkdir -p "$wt" "$outside" "$PROJECTS_DIR/generated-primary/.ddev"
  printf 'name: primary-review-01abcdefgh\n' > "$PROJECTS_DIR/generated-primary/.ddev/config.yaml"
  printf 'svvy-v2\nprotected-review-01abcdefgh\n' > "$CONFIG/ddev-protected-names"
  cat > "$DDEV_JSON" <<EOF
{"raw":[
{"name":"svvy-v2","approot":"$wt"},
{"name":"protected-review-01abcdefgh","approot":"$wt"},
{"name":"primary-review-01abcdefgh","approot":"$wt"},
{"name":"hub-test","approot":"$wt"},
{"name":"project-01abcdefgh-primary","approot":"$wt"},
{"name":"project-x01abcdefgh","approot":"$wt"},
{"name":"project-01abcdefgh","approot":"$wt"},
{"name":"smileadvantage-v3-pr1208-5ed446","approot":"$wt"},
{"name":"outside-01abcdefgh","approot":"$outside"},
{"name":"missing-01abcdefgh","approot":""}
]}
EOF
  for mode in fleet worktree; do
    : > "$ACTION_LOG"
    if [ "$mode" = fleet ]; then
      out=$(run_clean --apply) || fail "$mode cleanup failed: $out"
      assert_contains "$out" "protected: outside-01abcdefgh ($outside)" "outside primary root was not protected"
      assert_contains "$out" "ambiguous: missing-01abcdefgh (MISSING)" "unknown approot was not reported"
    else
      out=$(run_clean --worktree "$wt" --apply) || fail "$mode cleanup failed: $out"
    fi
    for name in svvy-v2 protected-review-01abcdefgh primary-review-01abcdefgh; do
      assert_contains "$out" "protected: $name ($wt)" "$mode failed protection for $name"
      assert_not_contains "$(cat "$ACTION_LOG")" " $name" "$mode mutated protected $name"
    done
    for name in hub-test project-01abcdefgh-primary project-x01abcdefgh; do
      assert_contains "$out" "ambiguous: $name ($wt)" "$mode accepted ambiguous $name"
      assert_not_contains "$(cat "$ACTION_LOG")" " $name" "$mode mutated ambiguous $name"
    done
    assert_grep 'ddev delete -Oy project-01abcdefgh' "$ACTION_LOG" "$mode rejected a generated ULID suffix"
    assert_grep 'ddev delete -Oy smileadvantage-v3-pr1208-5ed446' "$ACTION_LOG" "$mode rejected a generated PR suffix"
  done
  : > "$ACTION_LOG"
  out=$(run_clean --worktree "$outside" --ddev-name outside-01abcdefgh --apply)
  assert_contains "$out" "protected: outside-01abcdefgh ($outside)" "explicit worktree bypassed root protection"
  [ ! -s "$ACTION_LOG" ] || fail "outside worktree was mutated"
  : > "$ACTION_LOG"
  out=$(run_clean --worktree "$wt" --ddev-name svvy-v2 --apply)
  assert_contains "$out" "protected: svvy-v2 ($wt)" "explicit name bypassed protection"
  [ ! -s "$ACTION_LOG" ] || fail "explicit protected name was mutated"
  pass "fm-ddev-clean: both modes share protection and generated suffix eligibility"
}

test_worktree_only_deletes_the_recorded_ddev_name
test_fleet_cleanup_is_allowlist_only_and_safe
test_sweep_apply_runs_generated_cleanup_and_host_prune
test_missing_ddev_is_a_per_task_noop_and_sweep_error
test_selection_guards_apply_to_both_modes
