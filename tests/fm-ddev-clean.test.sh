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
DOCKER_PS="$TMP_ROOT/docker-ps"
DOCKER_CONTAINER_INSPECT="$TMP_ROOT/docker-container-inspect.json"
DOCKER_NETWORK_INSPECT="$TMP_ROOT/docker-network-inspect.json"
DOCKER_VOLUME_INSPECT="$TMP_ROOT/docker-volume-inspect.json"
mkdir -p "$HOME_DIR" "$STATE" "$DATA" "$CONFIG" "$PROJECTS_DIR"
printf '[]\n' > "$DOCKER_VOLUME_INSPECT"
: > "$DOCKER_PS"

cat > "$FAKEBIN/ddev" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = list ] && [ "${2:-}" = --json-output ]; then
  [ -z "${DDEV_JSON_PREFIX:-}" ] || printf '%s\n' "$DDEV_JSON_PREFIX"
  cat "$DDEV_JSON"
  exit 0
fi
printf 'ddev %s\n' "$*" >> "$ACTION_LOG"
if [ -n "${DDEV_TRANSITION:-}" ] && [ "${2:-}" != images ]; then
  python3 "$(dirname "$0")/ddev-transition"
fi
SH
cat > "$FAKEBIN/docker" <<'PYFAKE'
#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

args = sys.argv[1:]
containers = Path(os.environ["DOCKER_CONTAINER_INSPECT"])
networks = Path(os.environ["DOCKER_NETWORK_INSPECT"])
volumes = Path(os.environ["DOCKER_VOLUME_INSPECT"])
phase_file = Path(os.environ["DOCKER_PS"] + ".phase")
phase = int(phase_file.read_text()) if phase_file.exists() else 0
failure = os.environ.get("INVENTORY_FAILURE", "")

def read(path):
    return json.loads(path.read_text()) if path.exists() else []

def log():
    with open(os.environ["ACTION_LOG"], "a") as output:
        output.write("docker " + " ".join(args) + "\n")

if args[0] == "ps":
    phase += 1
    phase_file.write_text(str(phase))
    if failure == "ps-" + str(phase):
        sys.exit(1)
    print(Path(os.environ["DOCKER_PS"]).read_text(), end="")
elif args[:2] == ["volume", "ls"]:
    if failure == "volume-" + str(phase):
        sys.exit(1)
    print("\n".join(item["Name"] for item in read(volumes)))
elif args[0] == "inspect":
    if failure == "inspect-" + str(phase) and args[1].startswith("c-"):
        sys.exit(1)
    items = read(containers) + read(networks) + read(volumes)
    result = [item for item in items if item.get("Id") in args[1:] or item["Name"].lstrip("/") in args[1:]]
    if len(result) != len(args[1:]):
        sys.exit(1)
    print(json.dumps(result))
elif args[:2] == ["network", "ls"]:
    if failure == "network-" + str(phase):
        sys.exit(1)
    print("\n".join(item["Id"] for item in read(networks)))
elif args[0] == "rm":
    log()
    if os.environ.get("DOCKER_RM_FAIL") == args[1]:
        sys.exit(1)
    if os.environ.get("DOCKER_RM_RETAIN") != "1":
        remaining = [item for item in read(containers) if item["Id"] != args[1]]
        containers.write_text(json.dumps(remaining))
        Path(os.environ["DOCKER_PS"]).write_text("".join(item["Id"] + "\n" for item in remaining))
        current_networks = read(networks)
        for item in current_networks:
            item.get("Containers", {}).pop(args[1], None)
        networks.write_text(json.dumps(current_networks))
elif args[:2] == ["network", "rm"]:
    log()
    if os.environ.get("DOCKER_NETWORK_RETAIN") != "1":
        networks.write_text(json.dumps([item for item in read(networks) if item["Id"] != args[2]]))
elif args[:2] == ["volume", "rm"]:
    log()
    if os.environ.get("DOCKER_VOLUME_RM_FAIL") == args[2]:
        sys.exit(1)
    if os.environ.get("DOCKER_VOLUME_RETAIN") != "1":
        volumes.write_text(json.dumps([item for item in read(volumes) if item["Name"] != args[2]]))
else:
    log()
PYFAKE
cat > "$FAKEBIN/ddev-transition" <<'PYFAKE'
import json
import os
from pathlib import Path

path = Path(os.environ["DOCKER_CONTAINER_INSPECT"])
netpath = Path(os.environ["DOCKER_NETWORK_INSPECT"])
items = json.loads(path.read_text())
transition = os.environ["DDEV_TRANSITION"]
if transition == "deleted":
    items = []
    netpath.write_text("[]")
elif transition == "stopped":
    items[0]["State"]["Running"] = False
elif transition == "running":
    items[0]["State"]["Running"] = True
elif transition == "claimed":
    state = Path(os.environ["FM_STATE_OVERRIDE"])
    (state / "new-owner.meta").write_text("ddev_name=hub-test-5ed446\nworktree=" + os.environ["HOME"] + "/new-owner\n")
elif transition == "protected":
    (Path(os.environ["FM_CONFIG_OVERRIDE"]) / "ddev-protected-names").write_text("hub-test-5ed446\n")
elif transition == "relabeled":
    items[0]["Config"]["Labels"]["com.ddev.site-name"] = "another-site"
    items[0]["Config"]["Labels"]["com.docker.compose.project"] = "ddev-another-site"
elif transition == "new-container":
    extra = json.loads(json.dumps(items[0]))
    extra["Id"] = "c-new"
    extra["Name"] = "/ddev-new-redis"
    items.append(extra)
    nets = json.loads(netpath.read_text())
    nets[0]["Containers"]["c-new"] = {}
    netpath.write_text(json.dumps(nets))
path.write_text(json.dumps(items))
Path(os.environ["DOCKER_PS"]).write_text("".join(item["Id"] + "\n" for item in items))
PYFAKE
chmod +x "$FAKEBIN/ddev" "$FAKEBIN/docker"

run_clean() {
  rm -f "$DOCKER_PS.phase"
  HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" FM_PROJECTS_OVERRIDE="$PROJECTS_DIR" \
    DDEV_JSON="$DDEV_JSON" ACTION_LOG="$ACTION_LOG" DOCKER_PS="$DOCKER_PS" \
    DOCKER_CONTAINER_INSPECT="$DOCKER_CONTAINER_INSPECT" DOCKER_NETWORK_INSPECT="$DOCKER_NETWORK_INSPECT" \
    DOCKER_VOLUME_INSPECT="$DOCKER_VOLUME_INSPECT" DOCKER_RM_FAIL="${DOCKER_RM_FAIL:-}" \
    DOCKER_RM_RETAIN="${DOCKER_RM_RETAIN:-}" DOCKER_NETWORK_RETAIN="${DOCKER_NETWORK_RETAIN:-}" \
    DOCKER_VOLUME_RM_FAIL="${DOCKER_VOLUME_RM_FAIL:-}" DOCKER_VOLUME_RETAIN="${DOCKER_VOLUME_RETAIN:-}" \
    INVENTORY_FAILURE="${INVENTORY_FAILURE:-}" \
    DDEV_TRANSITION="${DDEV_TRANSITION:-}" \
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

test_recorded_and_legacy_normalized_task_names() {
  local wt out name
  wt="$HOME_DIR/.treehouse/identity/1/project"
  mkdir -p "$wt"
  fm_write_meta "$STATE/Fix_1.meta" "worktree=$wt"
  printf '{"raw":[{"name":"project-fix-1","approot":"%s"}]}\n' "$wt" > "$DDEV_JSON"
  : > "$ACTION_LOG"
  out=$(run_clean --worktree "$wt" --apply) || fail "legacy cleanup failed: $out"
  [ "$(cat "$ACTION_LOG")" = 'ddev delete -Oy project-fix-1' ] || fail "legacy normalized task was not cleaned"
  name="project-fix-1-$(python3 -c 'import hashlib; print(hashlib.sha256(b"Fix_1").hexdigest()[:6])')"
  printf '{"raw":[{"name":"%s","approot":"%s"}]}\n' "$name" "$wt" > "$DDEV_JSON"
  : > "$ACTION_LOG"
  out=$(run_clean --worktree "$wt" --apply) || fail "hashed suffix cleanup failed: $out"
  [ "$(cat "$ACTION_LOG")" = "ddev delete -Oy $name" ] || fail "shared hashed suffix was not recognized"
  fm_write_meta "$STATE/Fix_1.meta" "worktree=$wt" "ddev_name=custom-worker-identity"
  printf '{"raw":[{"name":"custom-worker-identity","approot":"%s"},{"name":"project-fix-1","approot":"%s"}]}\n' "$wt" "$wt" > "$DDEV_JSON"
  : > "$ACTION_LOG"
  out=$(run_clean --worktree "$wt" --apply) || fail "recorded cleanup failed: $out"
  [ "$(cat "$ACTION_LOG")" = 'ddev delete -Oy custom-worker-identity' ] || fail "recorded identity did not take precedence"
  rm "$STATE/Fix_1.meta"
  pass "fm-ddev-clean: recorded names take precedence and normalized legacy IDs remain eligible"
}

prepare_orphan_fixture() {
  printf 'c-orphan\nc-active\nc-protected\nc-foreign\nc-ambiguous\nc-mismatch\n' > "$DOCKER_PS"
  cat > "$DOCKER_CONTAINER_INSPECT" <<'EOF'
[
  {"Id":"c-orphan","Name":"/ddev-svvy-v2-pr1208-5ed446-redis","Config":{"Labels":{"com.ddev.site-name":"svvy-v2-pr1208-5ed446","com.docker.compose.project":"ddev-svvy-v2-pr1208-5ed446","com.docker.compose.service":"redis"}},"State":{"Running":false},"NetworkSettings":{"Networks":{"ddev-svvy-v2-pr1208-5ed446_default":{}}}},
  {"Id":"c-active","Name":"/ddev-svvy-v2-pr1208-5ed446-active","Config":{"Labels":{"com.ddev.site-name":"svvy-v2-pr1208-5ed446","com.docker.compose.project":"ddev-svvy-v2-pr1208-5ed446","com.docker.compose.service":"redis"}},"State":{"Running":true},"NetworkSettings":{"Networks":{}}},
  {"Id":"c-protected","Name":"/ddev-protected","Config":{"Labels":{"com.ddev.site-name":"protected-review-01abcdefgh","com.docker.compose.project":"ddev-protected-review-01abcdefgh","com.docker.compose.service":"redis"}},"State":{"Running":false},"NetworkSettings":{"Networks":{}}},
  {"Id":"c-foreign","Name":"/ddev-foreign","Config":{"Labels":{"com.ddev.site-name":"foreign-review-01abcdefgh","com.docker.compose.project":"ddev-another-project","com.docker.compose.service":"redis"}},"State":{"Running":false},"NetworkSettings":{"Networks":{}}},
  {"Id":"c-ambiguous","Name":"/ddev-ambiguous","Config":{"Labels":{"com.ddev.site-name":"unowned","com.docker.compose.project":"ddev-unowned","com.docker.compose.service":"redis"}},"State":{"Running":false},"NetworkSettings":{"Networks":{}}},
  {"Id":"c-mismatch","Name":"/ddev-mismatch","Config":{"Labels":{"com.ddev.site-name":"svvy-v2-pr1208-5ed446","com.docker.compose.project":"ddev-svvy-v2-pr1208-5ed446"}},"State":{"Running":false},"NetworkSettings":{"Networks":{}}}
]
EOF
  cat > "$DOCKER_NETWORK_INSPECT" <<'EOF'
[{"Id":"n-orphan","Name":"ddev-svvy-v2-pr1208-5ed446_default","Labels":{"com.docker.compose.project":"ddev-svvy-v2-pr1208-5ed446"},"Containers":{"c-orphan":{}}}]
EOF
  printf '[]\n' > "$DOCKER_VOLUME_INSPECT"

  printf 'protected-review-01abcdefgh\n' > "$CONFIG/ddev-protected-names"
  printf '{"raw":[]}\n' > "$DDEV_JSON"
  : > "$ACTION_LOG"
}

test_orphan_compose_inventory_is_safe_and_reports_residuals() {
  local out
  prepare_orphan_fixture
  out=$(run_clean) || fail "orphan dry-run failed: $out"
  assert_contains "$out" 'orphan-container: ddev-svvy-v2-pr1208-5ed446-redis (svvy-v2-pr1208-5ed446)' "orphan Redis was not inventoried"
  assert_contains "$out" 'orphan-network: ddev-svvy-v2-pr1208-5ed446_default (ddev-svvy-v2-pr1208-5ed446)' "orphan network was not inventoried"
  assert_contains "$out" 'residual-container: ddev-svvy-v2-pr1208-5ed446-active (svvy-v2-pr1208-5ed446 running)' "running container was not preserved"
  assert_contains "$out" 'residual-container: ddev-protected (protected-review-01abcdefgh protected)' "protected container was not preserved"
  assert_contains "$out" 'residual-container: ddev-foreign (label mismatch)' "foreign compose labels were not rejected"
  assert_contains "$out" 'residual-container: ddev-ambiguous (unowned ambiguous)' "ambiguous ownership was not preserved"
  [ ! -s "$ACTION_LOG" ] || fail "orphan dry-run mutated Docker: $(cat "$ACTION_LOG")"

  out=$(run_clean --apply) || fail "orphan apply failed: $out"
  assert_grep 'docker rm c-orphan' "$ACTION_LOG" "orphan container was not removed"
  assert_grep 'docker network rm n-orphan' "$ACTION_LOG" "now-empty orphan network was not removed"
  assert_not_contains "$(cat "$ACTION_LOG")" 'c-active' "running container was removed"
  assert_contains "$out" 'removed-container: ddev-svvy-v2-pr1208-5ed446-redis (svvy-v2-pr1208-5ed446)' "container success was not reported"
  assert_contains "$out" 'removed-network: ddev-svvy-v2-pr1208-5ed446_default (ddev-svvy-v2-pr1208-5ed446)' "network success was not reported"
  pass "fm-ddev-clean: stopped labeled compose leftovers are removed while exclusions remain"
}

prepare_volume_fixture() {
  local listed_root
  listed_root="$HOME_DIR/Sites/listed"
  mkdir -p "$listed_root"
  rm -rf "$STATE"
  mkdir -p "$STATE"
  : > "$DATA/backlog.md"
  printf 'sa-562-gnhf-657abd\nsa626-gnhf-5a4238\nprotected-review-01abcdefgh\n' > "$CONFIG/ddev-protected-names"
  printf '{"raw":[{"name":"listed-review-01abcdefgh","approot":"%s"}]}\n' "$listed_root" > "$DDEV_JSON"
  cat > "$DOCKER_CONTAINER_INSPECT" <<'EOF'
[{"Id":"c-stopped-mount","Name":"/stopped-mount","Config":{"Labels":{}},"State":{"Running":false},"Mounts":[{"Type":"volume","Name":"smileadvantage-check-mounted-mariadb"}],"NetworkSettings":{"Networks":{}}}]
EOF
  printf 'c-stopped-mount\n' > "$DOCKER_PS"
  printf '[]\n' > "$DOCKER_NETWORK_INSPECT"
  cat > "$DOCKER_VOLUME_INSPECT" <<'EOF'
[
  {"Name":"smileadvantage-check-abc123-mariadb","Labels":{}},
  {"Name":"smileadvantage-check-abc123-postgres","Labels":{}},
  {"Name":"sa-review-01abcdefgh-mariadb","Labels":{}},
  {"Name":"sa-review-01abcdefgh-postgres","Labels":{}},
  {"Name":"smileadvantage-v3-slice5-enrollment-mariadb","Labels":{}},
  {"Name":"smileadvantage-v3-slice5-enrollment-postgres","Labels":{}},
  {"Name":"smileadvantage-v3-nm-bootstrap-5ed446-5-mariadb","Labels":{}},
  {"Name":"smileadvantage-v3-nm-bootstrap-5ed446-5-postgres","Labels":{"com.ddev.site-name":"smileadvantage-v3-nm-bootstrap-5ed446-5"}},
  {"Name":"sa-review-01abcdefgh-mysql","Labels":{"com.ddev.site-name":"sa-review-01abcdefgh"}},
  {"Name":"smileadvantage-check-abc124-mariadb","Labels":{"com.ddev.site-name":"sa-review-01abcdefgh"}},
  {"Name":"smileadvantage-check-permanent-mariadb","Labels":{}},
  {"Name":"smileadvantage-v3-nm-bootstrap-permanent-postgres","Labels":{}},
  {"Name":"smileadvantage-v3-slice6-enrollment-mariadb","Labels":{}},
  {"Name":"smileadvantage-v3-slice5-enrollment-mysql","Labels":{}},
  {"Name":"ddev-labeled-volume","Labels":{"com.ddev.site-name":"smileadvantage-check-abc123"}},
  {"Name":"listed-review-01abcdefgh-mariadb","Labels":{}},
  {"Name":"protected-review-01abcdefgh-postgres","Labels":{}},
  {"Name":"sa-562-gnhf-657abd-mariadb","Labels":{}},
  {"Name":"sa626-gnhf-5a4238-postgres","Labels":{}},
  {"Name":"regular-mariadb","Labels":{}},
  {"Name":"smileadvantage-check-mounted-mariadb","Labels":{}}
]
EOF
  : > "$ACTION_LOG"
}

test_orphan_database_volumes_are_safe_and_reclaimed() {
  local out site database volume
  prepare_volume_fixture
  out=$(run_clean) || fail "volume dry-run failed: $out"
  for site in smileadvantage-check-abc123 sa-review-01abcdefgh smileadvantage-v3-slice5-enrollment smileadvantage-v3-nm-bootstrap-5ed446-5; do
    for database in mariadb postgres; do
      volume=$site-$database
      assert_contains "$out" "orphan-volume: $volume" "eligible volume was not inventoried: $volume"
    done
  done
  assert_contains "$out" 'orphan-volume=8' "unexpected volume selection"
  assert_contains "$out" 'residual-volume: smileadvantage-check-abc124-mariadb (label mismatch)' "conflicting label was accepted"
  assert_contains "$out" 'residual-volume: listed-review-01abcdefgh-mariadb (listed-review-01abcdefgh listed)' "listed volume was not preserved"
  assert_contains "$out" 'residual-volume: protected-review-01abcdefgh-postgres (protected-review-01abcdefgh protected)' "protected volume was not preserved"
  assert_contains "$out" 'residual-volume: sa-562-gnhf-657abd-mariadb (sa-562-gnhf-657abd protected)' "gnhf volume was not preserved"
  assert_contains "$out" 'residual-volume: regular-mariadb (regular not allowlisted)' "regular volume was not preserved"
  assert_contains "$out" 'residual-volume: smileadvantage-check-mounted-mariadb (smileadvantage-check-mounted in use)' "stopped-container mount was not preserved"
  [ ! -s "$ACTION_LOG" ] || fail "volume dry-run mutated Docker: $(cat "$ACTION_LOG")"

  out=$(run_clean --apply) || fail "volume apply failed: $out"
  for site in smileadvantage-check-abc123 sa-review-01abcdefgh smileadvantage-v3-slice5-enrollment smileadvantage-v3-nm-bootstrap-5ed446-5; do
    for database in mariadb postgres; do
      volume=$site-$database
      assert_grep "docker volume rm $volume" "$ACTION_LOG" "eligible volume was not removed: $volume"
      assert_contains "$out" "removed-volume: $volume" "eligible volume removal was not reported: $volume"
    done
  done
  python3 - "$DOCKER_VOLUME_INSPECT" <<'PYVOLUMES' || fail "volume cleanup did not preserve exactly the excluded volumes"
import json, sys
remaining = {item["Name"] for item in json.load(open(sys.argv[1]))}
expected = {
    "listed-review-01abcdefgh-mariadb", "protected-review-01abcdefgh-postgres",
    "sa-562-gnhf-657abd-mariadb", "sa626-gnhf-5a4238-postgres", "regular-mariadb",
    "smileadvantage-check-mounted-mariadb", "ddev-labeled-volume",
    "smileadvantage-v3-slice5-enrollment-mysql", "sa-review-01abcdefgh-mysql",
    "smileadvantage-check-abc124-mariadb", "smileadvantage-check-permanent-mariadb",
    "smileadvantage-v3-nm-bootstrap-permanent-postgres", "smileadvantage-v3-slice6-enrollment-mariadb",
}
assert remaining == expected, (remaining, expected)
PYVOLUMES
  assert_not_contains "$(cat "$ACTION_LOG")" 'docker volume rm listed-review-01abcdefgh-mariadb' "listed volume was removed"
  assert_not_contains "$(cat "$ACTION_LOG")" 'docker volume rm smileadvantage-check-mounted-mariadb' "mounted volume was removed"
  pass "fm-ddev-clean: orphan database volumes respect ownership and stopped mounts"
}

test_reported_sixty_volume_cleanup() {
  local preview applied repeated evidence=${FM_DDEV_TEST_EVIDENCE_DIR:-}
  prepare_volume_fixture
  python3 - "$DOCKER_VOLUME_INSPECT" "$TMP_ROOT/expected-removed.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
volumes = json.loads(path.read_text())
sites = ["smileadvantage-check-abc123"] + [f"smileadvantage-check-{i:06x}" for i in range(26)]
sites += ["sa-review-01abcdefgh", "smileadvantage-v3-slice5-enrollment",
          "smileadvantage-v3-nm-bootstrap-5ed446-5"]
expected = {f"{site}-{db}" for site in sites for db in ("mariadb", "postgres")}
existing = {v["Name"] for v in volumes}
volumes += [{"Name": name, "Labels": {}} for name in sorted(expected - existing)]
path.write_text(json.dumps(volumes, indent=2) + "\n")
Path(sys.argv[2]).write_text(json.dumps(sorted(expected), indent=2) + "\n")
PY
  cp "$DOCKER_VOLUME_INSPECT" "$TMP_ROOT/volumes-before.json"
  preview=$(run_clean) || fail "60-volume preview failed: $preview"
  assert_contains "$preview" 'orphan-volume=60 ' "preview missed reported orphan volumes"
  [ ! -s "$ACTION_LOG" ] || fail "60-volume preview mutated resources"
  cmp -s "$TMP_ROOT/volumes-before.json" "$DOCKER_VOLUME_INSPECT" || fail "preview changed volumes"
  applied=$(run_clean --apply) || fail "60-volume apply failed: $applied"
  assert_contains "$applied" 'volume-removed=60 ' "apply did not verify all 60 removals"
  assert_contains "$applied" 'volume-failed=0 ' "60-volume apply reported failures"
  python3 - "$TMP_ROOT/volumes-before.json" "$DOCKER_VOLUME_INSPECT" "$TMP_ROOT/expected-removed.json" "$ACTION_LOG" <<'PY' || fail "60-volume cleanup changed unexpected resources"
import json, sys
from pathlib import Path
before, after = [{v["Name"] for v in json.loads(Path(p).read_text())} for p in sys.argv[1:3]]
expected = set(json.loads(Path(sys.argv[3]).read_text()))
actions = Path(sys.argv[4]).read_text().splitlines()
assert len(expected) == 60
assert before - after == expected
assert after == before - expected
removals = [line for line in actions if line.startswith("docker volume rm ")]
assert len(removals) == 60
assert set(removals) == {"docker volume rm " + name for name in expected}
assert not any(line.startswith(("ddev delete -Oy", "ddev stop")) for line in actions)
assert not any("-a" in line.split() or "--all" in line.split() for line in actions)
PY
  cp "$ACTION_LOG" "$TMP_ROOT/first-apply-actions.log"
  : > "$ACTION_LOG"
  repeated=$(run_clean --apply) || fail "repeat cleanup failed: $repeated"
  assert_contains "$repeated" 'orphan-volume=0 ' "repeat selected already removed volumes"
  assert_not_contains "$(cat "$ACTION_LOG")" 'docker volume rm ' "repeat attempted further volume deletion"
  if [ -n "$evidence" ]; then
    mkdir -p "$evidence"
    {
      printf 'Real fm-ddev-clean.sh CLI; stateful Docker/DDEV test doubles (no host Docker mutations).\n'
      printf 'Fixture: 27 check sites, one review, one worker preview, one bootstrap; both database families.\n'
      printf 'No surviving task records or backlog entries. Protected, listed, mounted, regular and out-of-scope volumes coexist.\n\n'
      printf '$ bin/fm-ddev-clean.sh\n%s\n\n' "$preview"
      printf '$ bin/fm-ddev-clean.sh --apply\n%s\n\n' "$applied"
      printf 'Docker/DDEV mutation requests during apply:\n'
      cat "$TMP_ROOT/first-apply-actions.log"
      printf '\n$ bin/fm-ddev-clean.sh --apply # repeated\n%s\n' "$repeated"
    } > "$evidence/sixty-volume-cli.txt"
    cp "$TMP_ROOT/volumes-before.json" "$evidence/volumes-before.json"
    cp "$DOCKER_VOLUME_INSPECT" "$evidence/volumes-after.json"
  fi
  pass "fm-ddev-clean: reported 60 orphan volumes reclaimed exactly once with exclusions preserved"
}

test_volume_names_do_not_expand_project_cleanup() {
  local out site listed_root
  prepare_volume_fixture
  listed_root="$HOME_DIR/.treehouse/listed/1/project"
  mkdir -p "$listed_root"
  python3 - "$DDEV_JSON" "$listed_root" <<'PYLISTED'
import json, sys
names = ["smileadvantage-check-abc123", "smileadvantage-v3-slice5-enrollment",
         "smileadvantage-v3-nm-bootstrap-5ed446-5"]
with open(sys.argv[1], "w") as stream:
    json.dump({"raw": [{"name": name, "approot": sys.argv[2]} for name in names]}, stream)
PYLISTED
  out=$(run_clean) || fail "listed volume dry-run failed: $out"
  for site in smileadvantage-check-abc123 smileadvantage-v3-slice5-enrollment smileadvantage-v3-nm-bootstrap-5ed446-5; do
    assert_contains "$out" "ambiguous: $site ($listed_root)" "volume name expanded project eligibility: $site"
    assert_contains "$out" "residual-volume: $site-mariadb ($site listed)" "listed database was selected: $site"
  done
  [ ! -s "$ACTION_LOG" ] || fail "listed volume dry-run mutated resources"
  out=$(run_clean --apply) || fail "listed volume apply failed: $out"
  assert_not_contains "$(cat "$ACTION_LOG")" 'ddev delete -Oy' "volume name authorized project deletion"
  assert_not_contains "$(cat "$ACTION_LOG")" 'ddev stop' "volume name authorized project stopping"
  for site in smileadvantage-check-abc123 smileadvantage-v3-slice5-enrollment smileadvantage-v3-nm-bootstrap-5ed446-5; do
    assert_not_contains "$(cat "$ACTION_LOG")" "docker volume rm $site-" "listed database was removed: $site"
  done
  assert_grep 'docker volume rm sa-review-01abcdefgh-postgres' "$ACTION_LOG" "unlisted volume was not reclaimed"
  pass "fm-ddev-clean: volume name recognition preserves listed managed projects"
}

test_orphan_database_volume_failure_is_visible() {
  local out
  prepare_volume_fixture
  out=$(DOCKER_VOLUME_RM_FAIL=sa-review-01abcdefgh-postgres run_clean --apply) || fail "failed volume apply should continue: $out"
  assert_contains "$out" 'residual-volume: sa-review-01abcdefgh-postgres (sa-review-01abcdefgh removal failed)' "failed volume removal was not residual"
  assert_contains "$out" 'volume-failed=1' "failed volume removal was not counted"
  pass "fm-ddev-clean: failed orphan volume removal remains visible"
}

test_orphan_removal_failure_is_residual() {
  local out
  prepare_orphan_fixture
  printf '{"raw":[]}\n' > "$DDEV_JSON"
  : > "$ACTION_LOG"
  out=$(DOCKER_RM_FAIL=c-orphan run_clean --apply) || fail "failed orphan apply should continue: $out"
  assert_contains "$out" 'residual-container: ddev-svvy-v2-pr1208-5ed446-redis (svvy-v2-pr1208-5ed446 removal failed)' "failed removal was not residual"
  assert_contains "$out" 'failed=1' "failed removal was not counted"
  assert_not_contains "$(cat "$ACTION_LOG")" 'docker network rm n-orphan' "referenced network was removed after container failure"
  : > "$DOCKER_PS"
  rm -f "$DOCKER_CONTAINER_INSPECT" "$DOCKER_NETWORK_INSPECT"
  : > "$CONFIG/ddev-protected-names"
  pass "fm-ddev-clean: failed orphan removal remains visible and preserves its network"
}

prepare_transition_fixture() {
  local running=${1:-false}
  rm -rf "$STATE"
  mkdir -p "$STATE" "$HOME_DIR/.treehouse/reinventory/1/project"
  : > "$CONFIG/ddev-protected-names"
  : > "$ACTION_LOG"
  printf '{"raw":[{"name":"hub-test-5ed446","approot":"%s"}]}\n' \
    "$HOME_DIR/.treehouse/reinventory/1/project" > "$DDEV_JSON"
  printf 'c-approved\n' > "$DOCKER_PS"
  cat > "$DOCKER_CONTAINER_INSPECT" <<EOF
[{"Id":"c-approved","Name":"/ddev-approved-redis","Config":{"Labels":{"com.ddev.site-name":"hub-test-5ed446","com.docker.compose.project":"ddev-hub-test-5ed446","com.docker.compose.service":"redis"}},"State":{"Running":$running},"NetworkSettings":{"Networks":{"ddev-approved_default":{}}}}]
EOF
  cat > "$DOCKER_NETWORK_INSPECT" <<'EOF'
[{"Id":"n-approved","Name":"ddev-approved_default","Labels":{"com.docker.compose.project":"ddev-hub-test-5ed446"},"Containers":{"c-approved":{}}}]
EOF
  printf '[]\n' > "$DOCKER_VOLUME_INSPECT"
}

test_post_ddev_inventory_tracks_actual_resources() {
  local out
  prepare_transition_fixture
  out=$(DDEV_TRANSITION=deleted run_clean --apply) || fail "$out"
  assert_not_contains "$(cat "$ACTION_LOG")" 'docker rm' "already-deleted container was removed again"
  assert_not_contains "$(cat "$ACTION_LOG")" 'docker network rm' "already-deleted network was removed again"
  assert_contains "$out" 'removed=2 residual=0 failed=0' "DDEV removal was not verified"

  prepare_transition_fixture true
  out=$(DDEV_TRANSITION=stopped run_clean --apply) || fail "$out"
  assert_grep 'docker rm c-approved' "$ACTION_LOG" "approved running service retained by DDEV was missed"
  assert_grep 'docker network rm n-approved' "$ACTION_LOG" "retained service network was missed"
  assert_contains "$out" 'removed=2 residual=0 failed=0' "stopped retained service was not verified"
  pass "fm-ddev-clean: refresh handles DDEV-deleted and stopped retained services"
}

test_refresh_preserves_exclusions_and_approval_scope() {
  local transition out
  for transition in running claimed protected relabeled; do
    prepare_transition_fixture
    out=$(DDEV_TRANSITION="$transition" run_clean --apply) || fail "$out"
    assert_not_contains "$(cat "$ACTION_LOG")" 'docker rm' "$transition container was removed"
    assert_not_contains "$(cat "$ACTION_LOG")" 'docker network rm' "$transition network was removed"
    assert_contains "$out" 'removed=0 residual=2 failed=0' "$transition remaining state was misreported"
  done
  prepare_transition_fixture
  out=$(DDEV_TRANSITION=new-container run_clean --apply) || fail "$out"
  assert_grep 'docker rm c-approved' "$ACTION_LOG" "approved container was not removed"
  assert_not_contains "$(cat "$ACTION_LOG")" 'docker rm c-new' "refresh expanded approved resources"
  assert_contains "$out" 'removed=1 residual=2 failed=0' "new resource was not reported"

  prepare_transition_fixture true
  out=$(DDEV_TRANSITION=stopped run_clean) || fail "$out"
  [ ! -s "$ACTION_LOG" ] || fail "refresh mutated resources during preview"
  assert_contains "$(cat "$DOCKER_CONTAINER_INSPECT")" '"Running":true' "preview stopped service"

  prepare_transition_fixture true
  fm_write_meta "$STATE/task.meta" "worktree=$HOME_DIR/.treehouse/reinventory/1/project" "ddev_name=hub-test-5ed446"
  out=$(DDEV_TRANSITION=stopped run_clean --worktree "$HOME_DIR/.treehouse/reinventory/1/project" --apply) || fail "$out"
  assert_contains "$out" 'removed=2 residual=0 failed=0' "task-scoped retained service was missed"
  assert_not_contains "$(cat "$ACTION_LOG")" 'prune' "task cleanup expanded to host prune"
  pass "fm-ddev-clean: refresh preserves exclusions, resource approval, preview and task scope"
}

test_legacy_teardown_cleans_only_selected_listed_resources() {
  local wt other out
  prepare_transition_fixture true
  wt="$HOME_DIR/.treehouse/reinventory/1/project"
  other="$HOME_DIR/.treehouse/unrelated/2/project"
  mkdir -p "$other"
  fm_write_meta "$STATE/Fix_1.meta" "worktree=$wt"
  python3 - "$DDEV_JSON" "$DOCKER_CONTAINER_INSPECT" "$DOCKER_NETWORK_INSPECT" "$DOCKER_PS" "$wt" "$other" <<'PYFIXTURE'
import copy
import json
import sys
from pathlib import Path

projects, containers, networks, inventory = map(Path, sys.argv[1:5])
worktree, other = sys.argv[5:]
container = json.loads(containers.read_text())[0]
network = json.loads(networks.read_text())[0]
rows, container_rows, network_rows = [], [], []
for ident, site, root in [
    ("approved", "project-fix-1", worktree),
    ("unrelated", "other-fix-1", other),
    ("unlisted", "unlisted-fix-1", None),
    ("regular", "regular", worktree),
]:
    if root is not None:
        rows.append({"name": site, "approot": root})
    current = copy.deepcopy(container)
    current["Id"] = "c-" + ident
    current["Name"] = "/ddev-" + site + "-redis"
    current["Config"]["Labels"]["com.ddev.site-name"] = site
    current["Config"]["Labels"]["com.docker.compose.project"] = "ddev-" + site
    current["State"]["Running"] = ident == "approved"
    current["NetworkSettings"]["Networks"] = {"ddev-" + site + "_default": {}}
    container_rows.append(current)
    current_network = copy.deepcopy(network)
    current_network["Id"] = "n-" + ident
    current_network["Name"] = "ddev-" + site + "_default"
    current_network["Labels"]["com.docker.compose.project"] = "ddev-" + site
    current_network["Containers"] = {current["Id"]: {}}
    network_rows.append(current_network)
projects.write_text(json.dumps({"raw": rows}))
containers.write_text(json.dumps(container_rows))
networks.write_text(json.dumps(network_rows))
inventory.write_text("".join(item["Id"] + "\n" for item in container_rows))
PYFIXTURE
  out=$(run_clean --worktree "$wt") || fail "$out"
  [ ! -s "$ACTION_LOG" ] || fail "legacy preview mutated resources"
  assert_contains "$out" 'orphan-container: ddev-project-fix-1-redis' "legacy selected service was not approved"
  out=$(DDEV_TRANSITION=stopped run_clean --worktree "$wt" --apply) || fail "$out"
  [ "$(cat "$ACTION_LOG")" = "$(printf '%s\n' 'ddev delete -Oy project-fix-1' 'docker rm c-approved' 'docker network rm n-approved')" ] \
    || fail "legacy teardown acted outside its selected project: $(cat "$ACTION_LOG")"
  assert_contains "$out" 'removed-container: ddev-project-fix-1-redis' "legacy service removal was not verified"
  assert_contains "$out" 'removed-network: ddev-project-fix-1_default' "legacy network removal was not verified"
  python3 - "$DOCKER_CONTAINER_INSPECT" "$DOCKER_NETWORK_INSPECT" <<'PYVERIFY' || fail "legacy teardown did not preserve unrelated Docker resources"
import json
import sys
from pathlib import Path

containers, networks = [json.loads(Path(path).read_text()) for path in sys.argv[1:]]
assert {item["Id"] for item in containers} == {"c-unrelated", "c-unlisted", "c-regular"}
assert {item["Id"] for item in networks} == {"n-unrelated", "n-unlisted", "n-regular"}
PYVERIFY
  pass "fm-ddev-clean: legacy teardown cleans selected listed services and preserves unrelated resources"
}

test_final_inventory_does_not_trust_command_success() {
  local out
  prepare_transition_fixture
  out=$(DOCKER_RM_RETAIN=1 run_clean --apply) || fail "$out"
  assert_contains "$out" 'removed=0 residual=2 failed=0' "successful no-op removal hid resources"
  assert_not_contains "$out" 'removed-container:' "unverified container removal was reported"
  prepare_transition_fixture
  out=$(DOCKER_NETWORK_RETAIN=1 run_clean --apply) || fail "$out"
  assert_contains "$out" 'removed=1 residual=1 failed=0' "successful no-op network removal hid resource"
  assert_not_contains "$out" 'removed-network:' "unverified network removal was reported"
  pass "fm-ddev-clean: final summary measures remaining state"
}

test_refresh_inventory_failures_are_visible() {
  local failure out
  for failure in ps-1 inspect-1 ps-2 inspect-2 ps-3 inspect-3 network-2 network-3; do
    prepare_transition_fixture
    if [ "$failure" = inspect-3 ]; then
      out=$(DOCKER_RM_RETAIN=1 INVENTORY_FAILURE="$failure" run_clean --apply 2>&1) || fail "$out"
    else
      out=$(INVENTORY_FAILURE="$failure" run_clean --apply 2>&1) || fail "$out"
    fi
    assert_contains "$out" 'inventory incomplete' "$failure was not reported"
    assert_contains "$out" 'failed=1' "$failure was not counted"
    case "$failure" in
      ps-2|inspect-2)
        assert_not_contains "$(cat "$ACTION_LOG")" 'docker rm' "$failure used stale approval state" ;;
      ps-3|inspect-3)
        assert_not_contains "$out" 'removed-container:' "$failure claimed unverified removal" ;;
    esac
  done
  pass "fm-ddev-clean: inventory failures prevent unverified success"
}

test_worktree_only_deletes_the_recorded_ddev_name
test_fleet_cleanup_is_allowlist_only_and_safe
test_sweep_apply_runs_generated_cleanup_and_host_prune
test_missing_ddev_is_a_per_task_noop_and_sweep_error
test_selection_guards_apply_to_both_modes
test_orphan_compose_inventory_is_safe_and_reports_residuals
test_orphan_database_volumes_are_safe_and_reclaimed
test_reported_sixty_volume_cleanup
test_volume_names_do_not_expand_project_cleanup
test_orphan_database_volume_failure_is_visible
test_orphan_removal_failure_is_residual

test_recorded_and_legacy_normalized_task_names

test_post_ddev_inventory_tracks_actual_resources
test_refresh_preserves_exclusions_and_approval_scope
test_final_inventory_does_not_trust_command_success
test_refresh_inventory_failures_are_visible

test_legacy_teardown_cleans_only_selected_listed_resources
