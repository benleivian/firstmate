#!/usr/bin/env bash
# Behavior tests for bin/fm-ddev-bloat-check.sh's daily Docker volume threshold check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-ddev-bloat-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-ddev-bloat-check)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
DOCKER_LOG="$TMP_ROOT/docker.log"
DF_JSON="$TMP_ROOT/df.json"
DAY=86400

cat > "$FAKEBIN/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
[ -z "${DOCKER_FAIL:-}" ] || exit 1
cat "$DF_JSON"
SH
chmod +x "$FAKEBIN/docker"

set_sizes() {  # <ddev-global-cache size> <other volume size>
  printf '{"Images":[],"Containers":[],"Volumes":[{"Name":"ddev-global-cache","Size":"%s"},{"Name":"site-mariadb","Size":"%s"},{"Name":"odd","Size":"N/A"}],"BuildCache":[]}\n' \
    "$1" "$2" > "$DF_JSON"
}

reset_home() {
  rm -rf "$HOME_DIR"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
  : > "$DOCKER_LOG"
}

run_check() {  # <now>
  FM_HOME="$HOME_DIR" FM_DDEV_BLOAT_NOW="$1" DOCKER_LOG="$DOCKER_LOG" DF_JSON="$DF_JSON" \
    DOCKER_FAIL="${DOCKER_FAIL:-}" PATH="$FAKEBIN:$PATH" "$CHECK" check
}

test_notifies_once_per_crossing() {
  local out
  reset_home
  set_sizes 5.043GB 10.9GB
  out=$(run_check "$DAY") || fail "under-threshold check failed: $out"
  [ -z "$out" ] || fail "under-threshold usage notified: $out"

  set_sizes 18.2GB 10GB
  out=$(run_check $((DAY * 2))) || fail "$out"
  assert_contains "$out" 'ddev-bloat: ddev-global-cache is 18.2 GB (threshold 15 GB)' "cache crossing was not reported"
  assert_contains "$out" '/ddevclean' "notification did not suggest /ddevclean"
  assert_not_contains "$out" 'local Docker volumes' "total under its threshold was reported"

  out=$(run_check $((DAY * 3))) || fail "$out"
  [ -z "$out" ] || fail "unchanged crossing notified again: $out"

  set_sizes 18.2GB 45GB
  out=$(run_check $((DAY * 4))) || fail "$out"
  assert_contains "$out" 'local Docker volumes total 63.2 GB (threshold 60 GB)' "new volume crossing was not reported"

  set_sizes 5GB 10GB
  out=$(run_check $((DAY * 5))) || fail "$out"
  [ -z "$out" ] || fail "recovery notified: $out"
  set_sizes 16GB 10GB
  out=$(run_check $((DAY * 6))) || fail "$out"
  assert_contains "$out" 'ddev-global-cache is 16.0 GB' "crossing after recovery was not reported"
  ! grep -qv '^system df ' "$DOCKER_LOG" || fail "check ran a Docker command other than system df: $(cat "$DOCKER_LOG")"
  pass "fm-ddev-bloat-check: notifies once per threshold crossing and never deletes"
}

test_runs_at_most_daily_and_retries_docker_failure() {
  local out
  reset_home
  set_sizes 1GB 1GB
  out=$(DOCKER_FAIL=1 run_check "$DAY") || fail "$out"
  [ -z "$out" ] || fail "docker failure notified: $out"
  run_check $((DAY + 60)) >/dev/null || fail "retry after docker failure failed"
  [ "$(grep -c 'system df' "$DOCKER_LOG")" = 2 ] || fail "docker failure did not retry on the next poll"
  run_check $((DAY * 2)) >/dev/null || fail "in-interval poll failed"
  [ "$(grep -c 'system df' "$DOCKER_LOG")" = 2 ] || fail "check measured again inside one day"
  pass "fm-ddev-bloat-check: evaluates at most daily and retries when Docker is unavailable"
}

test_config_thresholds_override_defaults() {
  local out
  reset_home
  printf '# local limits\nddev-global-cache-gb=4\nlocal-volumes-gb=0\n' > "$HOME_DIR/config/ddev-bloat-thresholds"
  set_sizes 5GB 10GB
  out=$(run_check "$DAY") || fail "$out"
  assert_contains "$out" 'ddev-global-cache is 5.0 GB (threshold 4 GB)' "configured cache threshold was ignored"
  assert_contains "$out" 'config/ddev-bloat-thresholds has an invalid line' "invalid threshold was not reported"
  assert_not_contains "$out" 'local Docker volumes' "invalid volume threshold replaced the default"
  pass "fm-ddev-bloat-check: config thresholds override defaults and invalid lines are reported"
}

test_arm_registers_and_disarm_removes() {
  local out
  reset_home
  out=$(FM_HOME="$HOME_DIR" "$CHECK" arm) || fail "arm failed: $out"
  assert_contains "$out" 'armed: state/ddev-bloat.check.sh' "arm did not report the shim"
  [ -x "$HOME_DIR/state/ddev-bloat.check.sh" ] && [ -f "$HOME_DIR/state/ddev-bloat.check-trust" ] \
    || fail "arm did not write and register the shim"
  set_sizes 20GB 1GB
  out=$(DOCKER_LOG="$DOCKER_LOG" DF_JSON="$DF_JSON" PATH="$FAKEBIN:$PATH" "$HOME_DIR/state/ddev-bloat.check.sh") \
    || fail "armed shim failed: $out"
  assert_contains "$out" 'ddev-bloat: ddev-global-cache is 20.0 GB' "armed shim did not run the check"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" disarm) || fail "disarm failed: $out"
  [ ! -e "$HOME_DIR/state/ddev-bloat.check.sh" ] && [ ! -e "$HOME_DIR/state/ddev-bloat.check-trust" ] \
    && [ ! -e "$HOME_DIR/state/.ddev-bloat-check" ] || fail "disarm left check files"
  pass "fm-ddev-bloat-check: arm registers a watcher check and disarm removes it"
}

test_notifies_once_per_crossing
test_runs_at_most_daily_and_retries_docker_failure
test_config_thresholds_override_defaults
test_arm_registers_and_disarm_removes
