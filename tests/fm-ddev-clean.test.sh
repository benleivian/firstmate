#!/usr/bin/env bash
# Behavior tests for bin/fm-ddev-clean.sh's strictly scoped DDEV cleanup.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLEAN="$ROOT/bin/fm-ddev-clean.sh"
TMP_ROOT=$(fm_test_tmproot fm-ddev-clean)
HOME_DIR="$TMP_ROOT/home"
STATE="$TMP_ROOT/state"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
DDEV_JSON="$TMP_ROOT/projects.json"
ACTION_LOG="$TMP_ROOT/actions.log"
mkdir -p "$HOME_DIR" "$STATE"

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
  HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" DDEV_JSON="$DDEV_JSON" ACTION_LOG="$ACTION_LOG" \
    DDEV_JSON_PREFIX='{"level":"info","msg":"table follows"}' PATH="$FAKEBIN:$PATH" \
    FM_DDEV_CLEAN_TIMEOUT_SECS=5 "$CLEAN" "$@"
}

write_projects() {
  cat > "$DDEV_JSON" <<EOF
{"raw":[
{"name":"smileadvantage-review-01m1ezrq","approot":"$HOME_DIR/.no-mistakes/worktrees/1289b3aed15b/01M1EZRQV0Z5EDA0JJSC3TQR4T","status":"running"},
{"name":"smileadvantage-sa581-review-01m1cd","approot":"$HOME_DIR/.no-mistakes/worktrees/1289b3aed15b/01M1CDPW1E9DD00NQ0MGHNC06Z","status":"running"},
{"name":"smileadvantage-v3-01m1ezrrsqt5fy0m87p067k9mp","approot":"$HOME_DIR/.no-mistakes/worktrees/1289b3aed15b/01M1EZRRSQT5FY0M87P067K9MP","status":"running"},
{"name":"smileadvantage-v3-01m1ezrrsrfr3t3v07q1rpdzhp","approot":"$HOME_DIR/.no-mistakes/worktrees/1289b3aed15b/01M1EZRRSRFR3T3V07Q1RPDZHP","status":"running"},
{"name":"smileadvantage-v3-01m1hg9va73nm4rdb36tm02y3y","approot":"$HOME_DIR/.no-mistakes/worktrees/1289b3aed15b/01M1HG9VA73NM4RDB36TM02Y3Y","status":"running"},
{"name":"smileadvantage-v3-1289b3aed15b","approot":"$HOME_DIR/.no-mistakes/worktrees/1289b3aed15b/01M1AZA6EHX2QAJ22B6J8CHF3Z","status":"running"},
{"name":"smileadvantage-v3-2-sentry","approot":"$HOME_DIR/.treehouse/smileadvantage-v3-5ed446/2/smileadvantage-v3","status":"running"},
{"name":"smileadvantage-v3-a4","approot":"$HOME_DIR/.treehouse/smileadvantage-v3-5ed446/1/smileadvantage-v3","status":"running"},
{"name":"smileadvantage-v3-pr1208-5ed446","approot":"$HOME_DIR/.treehouse/smileadvantage-v3-5ed446/4/smileadvantage-v3","status":"running"},
{"name":"smileadvantage-v3-pr1341","approot":"$HOME_DIR/.treehouse/smileadvantage-v3-5ed446/5/smileadvantage-v3","status":"running"},
{"name":"smileadvantage-v3-smileadvantage-v3-5ed446-3","approot":"$HOME_DIR/.treehouse/smileadvantage-v3-5ed446/3/smileadvantage-v3","status":"running"},
{"name":"acst-assessments","approot":"$HOME_DIR/Sites/acst/acst-assessments","status":"running"}
]}
EOF
}

prepare_sweep_fixture() {
  local slot
  rm -rf "$STATE"
  mkdir -p "$STATE" "$HOME_DIR/Sites/acst/acst-assessments"
  for slot in 1 2 3 4 5; do
    mkdir -p "$HOME_DIR/.treehouse/smileadvantage-v3-5ed446/$slot/smileadvantage-v3"
  done
  fm_write_meta "$STATE/live-one.meta" "worktree=$HOME_DIR/.treehouse/smileadvantage-v3-5ed446/1/smileadvantage-v3"
  fm_write_meta "$STATE/live-four.meta" "worktree=$HOME_DIR/.treehouse/smileadvantage-v3-5ed446/4/smileadvantage-v3"
  fm_write_meta "$STATE/live-five.meta" "worktree=$HOME_DIR/.treehouse/smileadvantage-v3-5ed446/5/smileadvantage-v3"
  write_projects
}

test_worktree_only_deletes_projects_inside_the_worktree() {
  local wt outside out
  wt="$TMP_ROOT/task"
  outside="$TMP_ROOT/outside"
  mkdir -p "$wt/nested" "$outside"
  cat > "$DDEV_JSON" <<EOF
{"raw":[{"name":"inside","approot":"$wt/nested","status":"running"},{"name":"outside","approot":"$outside","status":"running"}]}
EOF
  : > "$ACTION_LOG"
  out=$(run_clean --worktree "$wt" --apply) || fail "worktree cleanup failed: $out"
  [ "$(cat "$ACTION_LOG")" = 'ddev delete -Oy inside' ] \
    || fail "worktree cleanup deleted outside its worktree: $(cat "$ACTION_LOG")"
  assert_contains "$out" 'delete=1' "worktree cleanup summary did not count its deletion"
  pass "fm-ddev-clean: worktree cleanup deletes only its own DDEV project"
}

test_sweep_dry_run_classifies_only_managed_projects() {
  local out
  prepare_sweep_fixture
  : > "$ACTION_LOG"
  out=$(run_clean) || fail "sweep dry-run failed: $out"
  assert_contains "$out" 'would: ddev stop --remove-data --unlist smileadvantage-review-01m1ezrq' "dry-run missed a stale no-mistakes project"
  assert_contains "$out" 'would: ddev delete -Oy smileadvantage-v3-2-sentry' "dry-run missed an orphan pool project"
  assert_contains "$out" 'would: ddev delete -Oy smileadvantage-v3-smileadvantage-v3-5ed446-3' "dry-run missed the other orphan pool project"
  assert_not_contains "$out" 'smileadvantage-v3-a4' "dry-run selected a live pool project"
  assert_not_contains "$out" 'acst-assessments' "dry-run selected a project outside managed roots"
  [ ! -s "$ACTION_LOG" ] || fail "dry-run invoked a mutating command: $(cat "$ACTION_LOG")"
  pass "fm-ddev-clean: dry-run keeps live pool and Sites projects while classifying stale projects"
}

test_sweep_apply_runs_cleanup_in_order() {
  local expected actual
  prepare_sweep_fixture
  : > "$ACTION_LOG"
  run_clean --apply >/dev/null || fail "sweep apply failed"
  expected=$(cat <<'EOF'
ddev stop --remove-data --unlist smileadvantage-review-01m1ezrq
ddev stop --remove-data --unlist smileadvantage-sa581-review-01m1cd
ddev stop --remove-data --unlist smileadvantage-v3-01m1ezrrsqt5fy0m87p067k9mp
ddev stop --remove-data --unlist smileadvantage-v3-01m1ezrrsrfr3t3v07q1rpdzhp
ddev stop --remove-data --unlist smileadvantage-v3-01m1hg9va73nm4rdb36tm02y3y
ddev stop --remove-data --unlist smileadvantage-v3-1289b3aed15b
ddev delete -Oy smileadvantage-v3-2-sentry
ddev delete -Oy smileadvantage-v3-smileadvantage-v3-5ed446-3
docker volume prune -f
docker image prune -f
ddev delete images -y
docker system df
EOF
)
  actual=$(cat "$ACTION_LOG")
  [ "$actual" = "$expected" ] || fail "sweep actions were not ordered or scoped correctly"$'\n'"$actual"
  pass "fm-ddev-clean: apply runs stale, orphan, and Docker cleanup in order"
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

test_worktree_only_deletes_projects_inside_the_worktree
test_sweep_dry_run_classifies_only_managed_projects
test_sweep_apply_runs_cleanup_in_order
test_missing_ddev_is_a_per_task_noop_and_sweep_error
