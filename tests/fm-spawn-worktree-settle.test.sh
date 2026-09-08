#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop after `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  case "$name" in
    ddev-existing-*)
      mkdir -p "$proj/.ddev"
      fm_git_init_commit "$proj"
      if [ "$name" = ddev-existing-derived-primary ]; then
        printf 'name: wt-derived-primary\n' > "$proj/.ddev/config.yaml"
      else
        printf 'name: captain-project\n' > "$proj/.ddev/config.yaml"
      fi
      git -C "$proj" add .ddev/config.yaml
      git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'Add DDEV config'
      fm_git_add_origin "$proj" "$proj.origin.git"
      git -C "$proj" worktree add --quiet -b "wt-$name" "$wt"
      ;;
    *) fm_git_worktree "$proj" "$wt" "wt-$name" ;;
  esac
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise settled-worktree detection for $id.

## Firstmate spec
Record only the pane's stable worktree.
EOF
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read still only
# costs the loop's existing one-second inter-poll sleep to confirm - not an
# extra full cycle on top of that.
test_already_settled_pane_costs_one_confirm_sleep() {
  local rec id out status start end elapsed
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  start=$(date +%s)
  out=$(run_settle_spawn "$id")
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  [ "$elapsed" -le 5 ] || fail "already-settled pane took ${elapsed}s to confirm - expected close to the single inter-poll sleep"
  pass "an already-settled pane confirms via the existing inter-poll sleep, not an extra full cycle"
}

test_ddev_local_name_is_isolated_and_ignored() {
  local case_dir home proj wt fakebin countfile id out
  case_dir="$TMP_ROOT/ddev-local"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/worker-copy"
  id=spawn-ddev-z1
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  countfile="$case_dir/pane-call-count"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$proj/.ddev"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_init_commit "$proj"
  printf 'name: captain-project\n' > "$proj/.ddev/config.yaml"
  git -C "$proj" add .ddev/config.yaml
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'Add DDEV config'
  fm_git_add_origin "$proj" "$proj.origin.git"
  git -C "$proj" worktree add --quiet -b wt-ddev "$wt"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise local DDEV naming.

## Firstmate spec
Keep the DDEV override local.
EOF
  touch "$home/state/.last-watcher-beat"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$wt" FM_FAKE_PANE_STALE_READS=0 \
    FM_FAKE_PANE_COUNTFILE="$countfile" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off 2>&1)
  expect_code 0 "$?" "spawn with a committed DDEV config should succeed: $out"
  [ "$(cat "$wt/.ddev/config.local.yaml")" = "name: worker-copy-$id" ] \
    || fail "spawn did not write the isolated DDEV name"
  git -C "$wt" check-ignore --quiet .ddev/config.local.yaml \
    || fail "Git does not ignore the worker DDEV override"
  assert_grep "ddev_name=worker-copy-$id" "$home/state/$id.meta" \
    "spawn did not record the DDEV name"
  pass "fm-spawn: committed DDEV names are overridden locally per worker copy"
}

test_existing_ddev_local_name_requires_no_primary_conflict() {
  local variant id rec existing original out status
  for variant in primary protected worker; do
    id="spawn-existing-$variant-z1"
    rec=$(make_settle_case "ddev-existing-$variant" "$id" 0)
    read_settle_record "$rec"
    printf '.ddev/config.local.yaml\n' >> "$PROJ_DIR/.git/info/exclude"
    case "$variant" in
      primary) existing=captain-project ;;
      protected) existing=operator-kept ;;
      worker) existing="worker-$id" ;;
    esac
    printf 'operator-kept\n' > "$HOME_DIR/config/ddev-protected-names"
    printf 'name: %s\nphp_version: "8.3"\n' "$existing" > "$WT_DIR/.ddev/config.local.yaml"
    original=$(cat "$WT_DIR/.ddev/config.local.yaml")
    status=0
    out=$(run_settle_spawn "$id") || status=$?
    [ "$(cat "$WT_DIR/.ddev/config.local.yaml")" = "$original" ] || fail "$variant spawn overwrote local settings"
    if [ "$variant" = worker ]; then
      expect_code 0 "$status" "safe existing local name should be adopted: $out"
      assert_grep "ddev_name=$existing" "$HOME_DIR/state/$id.meta" "safe existing name was not recorded"
    else
      [ "$status" -ne 0 ] || fail "$variant primary identity was accepted"
      assert_contains "$out" "$WT_DIR/.ddev/config.local.yaml" "conflict error omitted its file"
      assert_contains "$out" "$existing" "conflict error omitted its name"
      if [ -f "$HOME_DIR/state/$id.meta" ]; then
        assert_no_grep "ddev_name=$existing" "$HOME_DIR/state/$id.meta" "conflicting primary identity was recorded"
      fi
    fi
  done
  pass "fm-spawn: existing local names preserve settings and refuse primary identities"
}

test_ddev_identity_normalization_and_collisions() {
  local id rec out status name first_name='' variant expected long_id
  long_id=$(printf 'long%.0s' {1..16})
  for id in Fix_1 fix-1 "$long_id"; do
    rec=$(make_settle_case "ddev-existing-identity-$id" "$id" 0)
    read_settle_record "$rec"
    status=0
    out=$(run_settle_spawn "$id") || status=$?
    expect_code 0 "$status" "identity spawn failed: $out"
    name=$(sed -n 's/^ddev_name=//p' "$HOME_DIR/state/$id.meta")
    [ -n "$name" ] && [ "${#name}" -le 63 ] || fail "DDEV name exceeds its limit or is absent: $name"
    case "$id" in
      Fix_1)
        expected=$(python3 -c 'import hashlib; print(hashlib.sha256(b"Fix_1").hexdigest()[:6])')
        [ "$name" = "wt-fix-1-$expected" ] || fail "changed ID did not retain its digest: $name"
        first_name=$name
        ;;
      fix-1)
        [ "$name" = wt-fix-1 ] && [ "$name" != "$first_name" ] || fail "distinct IDs collided"
        ;;
      *)
        expected=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:6])' "$id")
        case "$name" in *-"$expected") ;; *) fail "capped ID lost its digest: $name" ;; esac
        ;;
    esac
  done
  for variant in collision protected primary adopted; do
    id="derived-$variant"
    rec=$(make_settle_case "ddev-existing-derived-$variant" "$id" 0)
    read_settle_record "$rec"
    expected="wt-$id"
    case "$variant" in
      collision) fm_write_meta "$HOME_DIR/state/other.meta" "ddev_name=$expected" ;;
      protected) printf '%s\n' "$expected" > "$HOME_DIR/config/ddev-protected-names" ;;
      adopted)
        printf 'name: %s\n' "$expected" > "$WT_DIR/.ddev/config.local.yaml"
        fm_write_meta "$HOME_DIR/state/other.meta" "ddev_name=$expected"
        printf '.ddev/config.local.yaml\n' >> "$PROJ_DIR/.git/info/exclude"
        ;;
    esac
    status=0
    out=$(run_settle_spawn "$id") || status=$?
    [ "$status" -ne 0 ] || fail "$variant duplicate identity was accepted"
    assert_contains "$out" "$expected" "conflict did not identify its name"
    [ ! -f "$HOME_DIR/state/$id.meta" ] || fail "failed spawn recorded task metadata"
    if [ "$variant" != adopted ]; then
      [ ! -e "$WT_DIR/.ddev/config.local.yaml" ] || fail "refused spawn wrote local configuration"
    else
      [ "$(cat "$WT_DIR/.ddev/config.local.yaml")" = "name: $expected" ] || fail "refused spawn overwrote local configuration"
    fi
  done
  pass "fm-spawn: changed and capped IDs retain identity and occupied names are refused"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_ddev_local_name_is_isolated_and_ignored
test_existing_ddev_local_name_requires_no_primary_conflict
test_ddev_identity_normalization_and_collisions

echo "# all fm-spawn-worktree-settle tests passed"
