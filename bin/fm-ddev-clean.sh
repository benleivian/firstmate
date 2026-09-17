#!/usr/bin/env bash
# fm-ddev-clean.sh - safely remove DDEV resources Firstmate and no-mistakes leave behind.
#
# Usage:
#   fm-ddev-clean.sh [--apply]
#   fm-ddev-clean.sh --worktree <path> [--ddev-name <name>] [--apply]
#
# Dry-run is the default. --worktree deletes only projects inside that worktree,
# and, when a task's recorded ddev_name= is available, only that exact name.
# Both modes are allowlist-only: they consider recorded ddev_name values first,
# then task suffixes from state/*.meta or data/backlog.md via fm-ddev-name-lib.sh,
# names matching (^|-)01[0-9a-hjkmnp-tv-z]{8,25}$,
# or matching ^(nm|sa|smileadvantage|svvy|hub)[a-z0-9-]*-(test|review|pr[0-9]+)-[0-9a-hjkmnp-tv-z]{6,}$.
# docs/configuration.md "DDEV protected names" owns the local deny-list setup.
# Both modes protect registered project config names and names outside worker roots.
# Worker roots are ~/.no-mistakes/worktrees and ~/.treehouse/*/<numeric-slot>/*.
# Eligible names with no approot are reported ambiguous; fleet mode also protects live worktrees.
# state/*.meta worktree= entries protect those live roots and their descendants.
# A missing-but-resolved worker approot is stop-unlisted with --omit-snapshot.
# Every selected, protected, or ambiguous project prints <verb>: <name> (<approot|MISSING>).
# After DDEV cleanup, Docker inventory finds stopped custom-compose containers only when
# com.ddev.site-name, com.docker.compose.project=ddev-<site>, and a compose service agree.
# It removes only their now-empty, same-project referenced networks. A running, protected,
# ambiguous, mismatched, failed, or still-referenced resource is reported as residual.
# In fleet mode only, Docker volume prune, image prune, and DDEV image deletion are host-wide,
# dangling-only operations. It never uses -a/--all for cleanup.
# Every ddev, docker, and JSON-parser call has FM_DDEV_CLEAN_TIMEOUT_SECS seconds
# (default 30); failed cleanup commands warn and do not stop later cleanup.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
TIMEOUT_SECS="${FM_DDEV_CLEAN_TIMEOUT_SECS:-30}"
APPLY=0
WORKTREE=
DDEV_NAME=
MODE=fleet

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-ddev-name-lib.sh
. "$SCRIPT_DIR/fm-ddev-name-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'fm-ddev-clean: %s\n' "$*" >&2
  exit 2
}

case "$TIMEOUT_SECS" in
  ''|*[!0-9]*|0) die "FM_DDEV_CLEAN_TIMEOUT_SECS must be a positive integer" ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --worktree)
      [ "$#" -ge 2 ] || die "--worktree needs a path"
      [ -z "$WORKTREE" ] || die "--worktree may be supplied once"
      WORKTREE=$2
      shift 2
      ;;
    --ddev-name)
      [ "$#" -ge 2 ] || die "--ddev-name needs a name"
      [ -z "$DDEV_NAME" ] || die "--ddev-name may be supplied once"
      DDEV_NAME=$2
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

case "$DDEV_NAME" in
  ''|*[!a-z0-9-]*) [ -z "$DDEV_NAME" ] || die "--ddev-name must be DDEV-safe" ;;
esac

if ! command -v ddev >/dev/null 2>&1; then
  echo "fm-ddev-clean: ddev is not installed; no DDEV cleanup ran" >&2
  [ -n "$WORKTREE" ] && exit 0
  exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "fm-ddev-clean: docker is not installed; DDEV residual cleanup cannot be verified" >&2
  exit 1
fi

if [ -n "$WORKTREE" ]; then
  [ -d "$WORKTREE" ] || die "worktree is not a directory: $WORKTREE"
  WORKTREE=$(cd -P -- "$WORKTREE" && pwd -P)
  MODE=worktree
fi
HOME_ROOT=$(cd -P -- "$HOME" && pwd -P)

run_capture() {
  RUN_STATUS=0
  RUN_OUTPUT=$(fm_run_timed "$TIMEOUT_SECS" "$@" 2>&1) || RUN_STATUS=$?
  return "$RUN_STATUS"
}

run_cleanup() {
  local label=$1
  shift
  RUN_STATUS=0
  if ! run_capture "$@"; then
    printf 'warning: %s failed (exit %s): %s\n' "$label" "$RUN_STATUS" "$RUN_OUTPUT" >&2
    RUN_STATUS=0
    return 1
  fi
  RUN_STATUS=0
}

path_within() {
  local path=$1 root=$2
  [ "$path" = "$root" ] || case "$path" in "$root"/*) return 0 ;; *) return 1 ;; esac
}

is_managed_root() {
  local path=$1 remainder repo slot leaf
  path_within "$path" "$HOME_ROOT/.no-mistakes/worktrees" && return 0
  case "$path" in "$HOME_ROOT/.treehouse/"*) ;; *) return 1 ;; esac
  remainder=${path#"$HOME_ROOT/.treehouse/"}
  IFS=/ read -r repo slot leaf _ <<EOF
$remainder
EOF
  [ -n "$repo" ] && [ -n "$leaf" ] || return 1
  case "$slot" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}

is_live_worktree() {
  local path=$1 meta line live
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    live=
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in worktree=*) live=${line#worktree=} ;; esac
    done < "$meta"
    [ -n "$live" ] && [ -d "$live" ] || continue
    live=$(cd -P -- "$live" && pwd -P) || continue
    path_within "$path" "$live" && return 0
  done
  return 1
}

recorded_ddev_name_for_worktree() {
  local meta line recorded_worktree recorded_name
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    recorded_worktree=
    recorded_name=
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        worktree=*) recorded_worktree=${line#worktree=} ;;
        ddev_name=*) recorded_name=${line#ddev_name=} ;;
      esac
    done < "$meta"
    [ -n "$recorded_worktree" ] && [ -n "$recorded_name" ] || continue
    recorded_worktree=$(cd -P -- "$recorded_worktree" 2>/dev/null && pwd -P) || continue
    [ "$recorded_worktree" = "$WORKTREE" ] || continue
    printf '%s\n' "$recorded_name"
    return 0
  done
  return 1
}

protected_by_config() {
  local name=$1 line
  [ -f "$CONFIG/ddev-protected-names" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] && [ "${line#\#}" = "$line" ] || continue
    [ "$line" = "$name" ] && return 0
  done < "$CONFIG/ddev-protected-names"
  return 1
}

registered_project_name() {
  local name=$1 config configured
  for config in "$PROJECTS"/*/.ddev/config.yaml; do
    [ -f "$config" ] || continue
    configured=$(sed -nE 's/^[[:space:]]*name:[[:space:]]*([^[:space:]#]+).*/\1/p' "$config" | head -1)
    [ "$configured" = "$name" ] && return 0
  done
  return 1
}

is_recorded_task_suffix() {
  local name=$1 meta id backlog_id recorded line
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    recorded=
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ddev_name=*) recorded=${line#ddev_name=} ;; esac
    done < "$meta"
    if [ -n "$recorded" ]; then
      [ "$name" != "$recorded" ] || return 0
      continue
    fi
    id=$(basename "$meta" .meta)
    fm_ddev_task_name_matches "$name" "$id" && return 0
  done
  if [ -f "$DATA/backlog.md" ]; then
    while IFS= read -r backlog_id; do
      [ -n "$backlog_id" ] || continue
      [ ! -f "$STATE/$backlog_id.meta" ] || continue
      fm_ddev_task_name_matches "$name" "$backlog_id" && return 0
    done < <(sed -nE 's/^- \[[ x]\] ([a-zA-Z0-9][a-zA-Z0-9_-]*).*/\1/p' "$DATA/backlog.md")
  fi
  return 1
}

is_generated_name() {
  local name=$1
  is_recorded_task_suffix "$name" && return 0
  printf '%s\n' "$name" | grep -Eq '(^|-)01[0-9a-hjkmnp-tv-z]{8,25}$' && return 0
  printf '%s\n' "$name" | grep -Eq '^(nm|sa|smileadvantage|svvy|hub)[a-z0-9-]*-(test|review|pr[0-9]+)-[0-9a-hjkmnp-tv-z]{6,}$'
}

print_project() {
  local verb=$1 name=$2 approot=$3
  [ -n "$approot" ] || approot=MISSING
  printf '%s: %s (%s)\n' "$verb" "$name" "$approot"
}

project_verdict() {
  local name=$1 approot=$2
  if protected_by_config "$name" || registered_project_name "$name"; then
    printf '%s\n' protected
  elif [ -n "$approot" ] && ! is_managed_root "$approot"; then
    printf '%s\n' protected
  elif ! is_generated_name "$name" || [ -z "$approot" ]; then
    printf '%s\n' ambiguous
  elif [ "$MODE" = fleet ] && is_live_worktree "$approot"; then
    printf '%s\n' protected
  else
    printf '%s\n' eligible
  fi
}

select_project() {
  local name=$1 approot=$2 verdict
  verdict=$(project_verdict "$name" "$approot")
  case "$verdict" in
    protected) PROTECTED_COUNT=$((PROTECTED_COUNT + 1)) ;;
    ambiguous) AMBIGUOUS_COUNT=$((AMBIGUOUS_COUNT + 1)) ;;
    eligible) return 0 ;;
  esac
  print_project "$verdict" "$name" "$approot"
  return 1
}

RUN_STATUS=0
if ! run_capture ddev list --json-output; then
  printf 'fm-ddev-clean: ddev list failed (exit %s): %s\n' "$RUN_STATUS" "$RUN_OUTPUT" >&2
  exit 1
fi
PROJECTS_JSON=$(FM_DDEV_JSON="$RUN_OUTPUT" fm_run_timed "$TIMEOUT_SECS" python3 -c '
import json, os
text = os.environ["FM_DDEV_JSON"]
decoder = json.JSONDecoder()
start = 0
raw = None
while start < len(text):
    while start < len(text) and text[start].isspace():
        start += 1
    if start == len(text):
        break
    document, start = decoder.raw_decode(text, start)
    candidate = document.get("raw") if isinstance(document, dict) else None
    if isinstance(candidate, list):
        raw = candidate
        break
if raw is None:
    raise ValueError("ddev JSON has no raw array")
for project in raw:
    name = str(project.get("name") or "")
    approot = str(project.get("approot") or "")
    if not name:
        raise ValueError("ddev project lacks name")
    print("\x1f".join((name, os.path.realpath(approot) if approot else "", str(project.get("status") or ""))))
') || {
  echo "fm-ddev-clean: could not parse ddev list JSON" >&2
  exit 1
}

[ -n "$DDEV_NAME" ] || DDEV_NAME=$(recorded_ddev_name_for_worktree 2>/dev/null || true)
DELETE_NAMES=()
DELETE_ROOTS=()
STOP_NAMES=()
STOP_ROOTS=()
LIST_NAMES=()
LIST_ROOTS=()
DELETE_COUNT=0
STOP_COUNT=0
PROTECTED_COUNT=0
AMBIGUOUS_COUNT=0
# shellcheck disable=SC2034 # status is retained from DDEV's documented raw shape.
while IFS=$'\x1f' read -r name approot status; do
  [ -n "$name" ] || continue
  LIST_NAMES+=("$name")
  LIST_ROOTS+=("$approot")
  if [ -n "$WORKTREE" ]; then
    path_within "$approot" "$WORKTREE" || continue
    [ -z "$DDEV_NAME" ] || [ "$name" = "$DDEV_NAME" ] || continue
  fi
  select_project "$name" "$approot" || continue
  if [ ! -d "$approot" ]; then
    STOP_NAMES+=("$name")
    STOP_ROOTS+=("$approot")
    STOP_COUNT=$((STOP_COUNT + 1))
  else
    DELETE_NAMES+=("$name")
    DELETE_ROOTS+=("$approot")
    DELETE_COUNT=$((DELETE_COUNT + 1))
  fi
done <<EOF
$PROJECTS_JSON
EOF

orphan_owner_verdict() {
  local name=$1 meta line recorded root i
  if [ -n "$WORKTREE" ]; then
    [ -n "$DDEV_NAME" ] && [ "$name" = "$DDEV_NAME" ] || { printf '%s\n' ambiguous; return; }
  fi
  for i in "${!LIST_NAMES[@]}"; do
    [ "${LIST_NAMES[$i]}" = "$name" ] || continue
    project_verdict "$name" "${LIST_ROOTS[$i]}"
    return
  done
  if protected_by_config "$name" || registered_project_name "$name"; then
    printf '%s\n' protected
    return
  fi
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    recorded=
    root=
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        ddev_name=*) recorded=${line#ddev_name=} ;;
        worktree=*) root=${line#worktree=} ;;
      esac
    done < "$meta"
    [ "$recorded" = "$name" ] || continue
    if [ -n "$WORKTREE" ] && [ "$root" = "$WORKTREE" ]; then
      printf '%s\n' eligible
    else
      printf '%s\n' protected
    fi
    return
  done
  is_generated_name "$name" && printf '%s\n' eligible || printf '%s\n' ambiguous
}

docker_inspect_inventory() {
  local kind=$1
  shift
  [ "$#" -gt 0 ] || return 0
  if ! run_capture docker inspect "$@"; then
    printf 'warning: docker inspect %s failed (exit %s): %s\n' "$kind" "$RUN_STATUS" "$RUN_OUTPUT" >&2
    return 1
  fi
  FM_DDEV_DOCKER_JSON="$RUN_OUTPUT" FM_DDEV_DOCKER_KIND="$kind" FM_DDEV_DOCKER_EXPECTED="$#" fm_run_timed "$TIMEOUT_SECS" python3 -c '
import json, os
items = json.loads(os.environ["FM_DDEV_DOCKER_JSON"])
kind = os.environ["FM_DDEV_DOCKER_KIND"]
if not isinstance(items, list) or len(items) != int(os.environ["FM_DDEV_DOCKER_EXPECTED"]):
    raise ValueError("incomplete Docker inspection")
for item in items:
    labels = (item.get("Config", {}).get("Labels", {}) if kind == "container" else item.get("Labels", {})) or {}
    ident = str(item.get("Id") or item.get("ID") or "")
    name = str(item.get("Name") or "").lstrip("/")
    if not ident or not name:
        raise ValueError("Docker inspection lacks identity")
    if kind == "container":
        networks = ",".join(sorted((item.get("NetworkSettings", {}).get("Networks", {}) or {}).keys()))
        running = "running" if item.get("State", {}).get("Running") else "stopped"
        print("\x1f".join(("container", ident, name, str(labels.get("com.ddev.site-name") or ""), str(labels.get("com.docker.compose.project") or ""), str(labels.get("com.docker.compose.service") or ""), running, networks)))
    else:
        members = str(len(item.get("Containers", {}) or {}))
        print("\x1f".join(("network", ident, name, str(labels.get("com.docker.compose.project") or ""), members)))
' || return 1
}

ORPHAN_CONTAINER_IDS=()
ORPHAN_CONTAINER_NAMES=()
ORPHAN_CONTAINER_SITES=()
ORPHAN_CONTAINER_PROJECTS=()
ORPHAN_CONTAINER_NETWORKS=()
ORPHAN_CONTAINER_COUNT=0
ORPHAN_NETWORK_COUNT=0
ORPHAN_RESIDUAL_COUNT=0
ORPHAN_REMOVED_COUNT=0
ORPHAN_FAILED_COUNT=0
DDEV_REMOVED_COUNT=0
DDEV_FAILED_COUNT=0

container_inventory() {
  local ids=() id
  if ! run_capture docker ps -aq --no-trunc; then
    printf 'warning: docker container inventory failed (exit %s): %s\n' "$RUN_STATUS" "$RUN_OUTPUT" >&2
    return 1
  fi
  while IFS= read -r id; do
    [ -z "$id" ] || ids+=("$id")
  done <<< "$RUN_OUTPUT"
  [ "${#ids[@]}" -eq 0 ] || docker_inspect_inventory container "${ids[@]}"
}

inventory_failed() {
  printf 'warning: %s inventory incomplete; remaining resources unverified\n' "$1" >&2
  ORPHAN_FAILED_COUNT=$((ORPHAN_FAILED_COUNT + 1))
}

selected_ddev_site() {
  local index
  for index in "${!DELETE_NAMES[@]}"; do
    [ "${DELETE_NAMES[$index]}" != "$1" ] || return 0
  done
  for index in "${!STOP_NAMES[@]}"; do
    [ "${STOP_NAMES[$index]}" != "$1" ] || return 0
  done
  return 1
}

current_owner_verdict() {
  local site=$1 meta line recorded root
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    recorded= root=
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        ddev_name=*) recorded=${line#ddev_name=} ;;
        worktree=*) root=${line#worktree=} ;;
      esac
    done < "$meta"
    [ "$recorded" = "$site" ] || continue
    if [ "$MODE" = fleet ] || [ "$root" != "$WORKTREE" ]; then
      printf '%s\n' protected
      return
    fi
  done
  orphan_owner_verdict "$site"
}

INITIAL_CONTAINERS=
if ! INITIAL_CONTAINERS=$(container_inventory); then
  inventory_failed container
  INITIAL_CONTAINERS=
fi
if [ -n "$INITIAL_CONTAINERS" ]; then
  while IFS=$'\x1f' read -r kind ident resource_name site project service running networks; do
    [ "$kind" = container ] && [ -n "$site" ] || continue
    verdict=$(orphan_owner_verdict "$site")
    if [ -z "$site" ] || [ "$project" != "ddev-$site" ] || [ -z "$service" ]; then
      printf 'residual-container: %s (label mismatch)\n' "$resource_name"
      ORPHAN_RESIDUAL_COUNT=$((ORPHAN_RESIDUAL_COUNT + 1))
    elif [ "$verdict" != eligible ]; then
      printf 'residual-container: %s (%s %s)\n' "$resource_name" "$site" "$verdict"
      ORPHAN_RESIDUAL_COUNT=$((ORPHAN_RESIDUAL_COUNT + 1))
    elif [ "$running" = running ] && ! selected_ddev_site "$site"; then
      printf 'residual-container: %s (%s running)\n' "$resource_name" "$site"
      ORPHAN_RESIDUAL_COUNT=$((ORPHAN_RESIDUAL_COUNT + 1))
    else
      printf 'orphan-container: %s (%s)\n' "$resource_name" "$site"
      ORPHAN_CONTAINER_IDS+=("$ident")
      ORPHAN_CONTAINER_NAMES+=("$resource_name")
      ORPHAN_CONTAINER_SITES+=("$site")
      ORPHAN_CONTAINER_PROJECTS+=("$project")
      ORPHAN_CONTAINER_NETWORKS+=("$networks")
      ORPHAN_CONTAINER_COUNT=$((ORPHAN_CONTAINER_COUNT + 1))
    fi
  done <<< "$INITIAL_CONTAINERS"
fi

network_candidates() {
  local i network rows kind ident name project members networks=()
  for i in "${!ORPHAN_CONTAINER_IDS[@]}"; do
    IFS=, read -r -a networks <<< "${ORPHAN_CONTAINER_NETWORKS[$i]}"
    for network in "${networks[@]}"; do
      [ -n "$network" ] || continue
      rows=$(docker_inspect_inventory network "$network") || return 1
      while IFS=$'\x1f' read -r kind ident name project members; do
        if [ "$kind" = network ] && [ "$project" = "${ORPHAN_CONTAINER_PROJECTS[$i]}" ]; then
          printf '%s\x1f%s\x1f%s\x1f%s\n' "$ident" "$name" "$project" "$members"
        fi
      done <<< "$rows"
    done
  done
}

NETWORK_INVENTORY=
if NETWORK_INVENTORY=$(network_candidates); then
  NETWORK_INVENTORY=$(printf '%s\n' "$NETWORK_INVENTORY" | sort -u)
else
  inventory_failed network
  NETWORK_INVENTORY=
fi
while IFS=$'\x1f' read -r ident resource_name project members; do
  [ -n "$ident" ] || continue
  printf 'orphan-network: %s (%s)\n' "$resource_name" "$project"
  ORPHAN_NETWORK_COUNT=$((ORPHAN_NETWORK_COUNT + 1))
done <<EOF
$NETWORK_INVENTORY
EOF

if [ "$APPLY" -ne 1 ]; then
  for i in "${!STOP_NAMES[@]}"; do print_project stop-unlist "${STOP_NAMES[$i]}" "${STOP_ROOTS[$i]}"; done
  for i in "${!DELETE_NAMES[@]}"; do print_project delete "${DELETE_NAMES[$i]}" "${DELETE_ROOTS[$i]}"; done
  if [ -z "$WORKTREE" ]; then
    echo 'would: docker volume prune -f (host-wide, dangling-only)'
    echo 'would: docker image prune -f (host-wide, dangling-only)'
    echo 'would: ddev delete images -y (host-wide, dangling-only)'
  fi
  printf 'summary: stop-unlist=%s delete=%s orphan-container=%s orphan-network=%s residual=%s protected=%s ambiguous=%s mode=%s\n' \
    "$STOP_COUNT" "$DELETE_COUNT" "$ORPHAN_CONTAINER_COUNT" "$ORPHAN_NETWORK_COUNT" "$ORPHAN_RESIDUAL_COUNT" \
    "$PROTECTED_COUNT" "$AMBIGUOUS_COUNT" "$MODE"
  exit 0
fi

for i in "${!STOP_NAMES[@]}"; do
  print_project stop-unlist "${STOP_NAMES[$i]}" "${STOP_ROOTS[$i]}"
  if run_cleanup "ddev stop --remove-data --omit-snapshot --unlist ${STOP_NAMES[$i]}" \
    ddev stop --remove-data --omit-snapshot --unlist "${STOP_NAMES[$i]}"; then
    DDEV_REMOVED_COUNT=$((DDEV_REMOVED_COUNT + 1))
  else
    printf 'residual-project: %s (stop-unlist failed)\n' "${STOP_NAMES[$i]}"
    DDEV_FAILED_COUNT=$((DDEV_FAILED_COUNT + 1))
  fi
done
for i in "${!DELETE_NAMES[@]}"; do
  print_project delete "${DELETE_NAMES[$i]}" "${DELETE_ROOTS[$i]}"
  if run_cleanup "ddev delete -Oy ${DELETE_NAMES[$i]}" ddev delete -Oy "${DELETE_NAMES[$i]}"; then
    DDEV_REMOVED_COUNT=$((DDEV_REMOVED_COUNT + 1))
  else
    printf 'residual-project: %s (delete failed)\n' "${DELETE_NAMES[$i]}"
    DDEV_FAILED_COUNT=$((DDEV_FAILED_COUNT + 1))
  fi
done
if AFTER_CONTAINERS=$(container_inventory); then
  for i in "${!ORPHAN_CONTAINER_IDS[@]}"; do
    while IFS=$'\x1f' read -r kind ident resource_name site project service running networks; do
      [ "$ident" = "${ORPHAN_CONTAINER_IDS[$i]}" ] || continue
      [ "$site" = "${ORPHAN_CONTAINER_SITES[$i]}" ] && [ "$project" = "${ORPHAN_CONTAINER_PROJECTS[$i]}" ] \
        && [ -n "$service" ] && [ "$running" = stopped ] || continue
      [ "$(current_owner_verdict "$site")" = eligible ] || continue
      if ! run_cleanup "docker rm $ident" docker rm "$ident"; then
        printf 'residual-container: %s (%s removal failed)\n' "$resource_name" "$site"
        ORPHAN_FAILED_COUNT=$((ORPHAN_FAILED_COUNT + 1))
      fi
    done <<< "$AFTER_CONTAINERS"
  done
else
  inventory_failed post-ddev-container
fi

approved_network_inventory() {
  local existing ident name project members rows
  [ -n "$NETWORK_INVENTORY" ] || return 0
  run_capture docker network ls -q --no-trunc || return 1
  existing=$RUN_OUTPUT
  while IFS=$'\x1f' read -r ident name project members; do
    [ -n "$ident" ] || continue
    printf '%s\n' "$existing" | grep -Fxq "$ident" || continue
    rows=$(docker_inspect_inventory network "$ident") || return 1
    printf '%s\n' "$rows"
  done <<< "$NETWORK_INVENTORY"
}

if NETWORK_AFTER=$(approved_network_inventory); then
  while IFS=$'\x1f' read -r kind ident resource_name project members; do
    [ "$kind" = network ] || continue
    while IFS=$'\x1f' read -r approved_id approved_name approved_project _; do
      [ "$ident" = "$approved_id" ] && [ "$project" = "$approved_project" ] || continue
      [ "$members" = 0 ] && [ "$(current_owner_verdict "${project#ddev-}")" = eligible ] || continue
      if ! run_cleanup "docker network rm $ident" docker network rm "$ident"; then
        ORPHAN_FAILED_COUNT=$((ORPHAN_FAILED_COUNT + 1))
      fi
    done <<< "$NETWORK_INVENTORY"
  done <<< "$NETWORK_AFTER"
else
  inventory_failed post-ddev-network
fi

ORPHAN_RESIDUAL_COUNT=0
if FINAL_CONTAINERS=$(container_inventory); then
  while IFS=$'\x1f' read -r kind ident resource_name site project service running networks; do
    [ "$kind" = container ] || continue
    tracked=0
    for i in "${!ORPHAN_CONTAINER_IDS[@]}"; do
      [ "$ident" != "${ORPHAN_CONTAINER_IDS[$i]}" ] || tracked=1
    done
    [ -n "$site" ] || [ "$tracked" = 1 ] || continue
    printf 'residual-container: %s (%s %s, owner=%s)\n' "$resource_name" "$site" "$running" "$(current_owner_verdict "$site")"
    ORPHAN_RESIDUAL_COUNT=$((ORPHAN_RESIDUAL_COUNT + 1))
  done <<< "$FINAL_CONTAINERS"
  for i in "${!ORPHAN_CONTAINER_IDS[@]}"; do
    found=0
    while IFS=$'\x1f' read -r kind ident _; do
      [ "$ident" != "${ORPHAN_CONTAINER_IDS[$i]}" ] || found=1
    done <<< "$FINAL_CONTAINERS"
    [ "$found" = 0 ] || continue
    printf 'removed-container: %s (%s)\n' "${ORPHAN_CONTAINER_NAMES[$i]}" "${ORPHAN_CONTAINER_SITES[$i]}"
    ORPHAN_REMOVED_COUNT=$((ORPHAN_REMOVED_COUNT + 1))
  done
else
  inventory_failed final-container
  ORPHAN_RESIDUAL_COUNT=$((ORPHAN_RESIDUAL_COUNT + 1))
fi
if FINAL_NETWORKS=$(approved_network_inventory); then
  while IFS=$'\x1f' read -r approved_id approved_name approved_project _; do
    [ -n "$approved_id" ] || continue
    found=0
    while IFS=$'\x1f' read -r kind ident resource_name project members; do
      [ "$ident" = "$approved_id" ] || continue
      found=1
      printf 'residual-network: %s (%s still present, members=%s)\n' "$resource_name" "$project" "$members"
      ORPHAN_RESIDUAL_COUNT=$((ORPHAN_RESIDUAL_COUNT + 1))
    done <<< "$FINAL_NETWORKS"
    [ "$found" = 0 ] || continue
    printf 'removed-network: %s (%s)\n' "$approved_name" "$approved_project"
    ORPHAN_REMOVED_COUNT=$((ORPHAN_REMOVED_COUNT + 1))
  done <<< "$NETWORK_INVENTORY"
else
  inventory_failed final-network
  ORPHAN_RESIDUAL_COUNT=$((ORPHAN_RESIDUAL_COUNT + 1))
fi
if [ -z "$WORKTREE" ]; then
  run_cleanup 'docker volume prune -f' docker volume prune -f
  run_cleanup 'docker image prune -f' docker image prune -f
  run_cleanup 'ddev delete images -y' ddev delete images -y
  run_cleanup 'docker system df' docker system df
fi
printf 'summary: stop-unlist=%s delete=%s ddev-removed=%s ddev-failed=%s orphan-container=%s orphan-network=%s removed=%s residual=%s failed=%s protected=%s ambiguous=%s mode=%s\n' \
  "$STOP_COUNT" "$DELETE_COUNT" "$DDEV_REMOVED_COUNT" "$DDEV_FAILED_COUNT" "$ORPHAN_CONTAINER_COUNT" \
  "$ORPHAN_NETWORK_COUNT" "$ORPHAN_REMOVED_COUNT" "$ORPHAN_RESIDUAL_COUNT" \
  "$((DDEV_FAILED_COUNT + ORPHAN_FAILED_COUNT))" "$PROTECTED_COUNT" "$AMBIGUOUS_COUNT" "$MODE"
