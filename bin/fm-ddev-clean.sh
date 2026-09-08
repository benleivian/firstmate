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
# names ending in (^|-)01[0-9a-hjkmnp-tv-z]{8,25},
# or matching ^(nm|sa|smileadvantage|svvy|hub)[a-z0-9-]*-(test|review|pr[0-9]+)-[0-9a-hjkmnp-tv-z]{6,}$.
# config/ddev-protected-names is an optional local, one-name-per-line deny list.
# Both modes protect registered project config names and names outside worker roots.
# Eligible names with no approot are reported ambiguous; fleet mode also protects live worktrees.
# A missing-but-resolved worker approot is stop-unlisted with --omit-snapshot.
# Every selected, protected, or ambiguous project prints <verb>: <name> (<approot|MISSING>).
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
if [ -z "$WORKTREE" ] && ! command -v docker >/dev/null 2>&1; then
  echo "fm-ddev-clean: docker is not installed; fleet cleanup needs Docker" >&2
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

select_project() {
  local name=$1 approot=$2 verdict=
  if protected_by_config "$name" || registered_project_name "$name"; then
    verdict=protected
  elif [ -n "$approot" ] && ! is_managed_root "$approot"; then
    verdict=protected
  elif ! is_generated_name "$name"; then
    verdict=ambiguous
  elif [ -z "$approot" ]; then
    verdict=ambiguous
  elif [ "$MODE" = fleet ] && is_live_worktree "$approot"; then
    verdict=protected
  fi
  case "$verdict" in
    protected) PROTECTED_COUNT=$((PROTECTED_COUNT + 1)) ;;
    ambiguous) AMBIGUOUS_COUNT=$((AMBIGUOUS_COUNT + 1)) ;;
    *) return 0 ;;
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
DELETE_COUNT=0
STOP_COUNT=0
PROTECTED_COUNT=0
AMBIGUOUS_COUNT=0
# shellcheck disable=SC2034 # status is retained from DDEV's documented raw shape.
while IFS=$'\x1f' read -r name approot status; do
  [ -n "$name" ] || continue
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

if [ "$APPLY" -ne 1 ]; then
  for i in "${!STOP_NAMES[@]}"; do print_project stop-unlist "${STOP_NAMES[$i]}" "${STOP_ROOTS[$i]}"; done
  for i in "${!DELETE_NAMES[@]}"; do print_project delete "${DELETE_NAMES[$i]}" "${DELETE_ROOTS[$i]}"; done
  if [ -z "$WORKTREE" ]; then
    echo 'would: docker volume prune -f (host-wide, dangling-only)'
    echo 'would: docker image prune -f (host-wide, dangling-only)'
    echo 'would: ddev delete images -y (host-wide, dangling-only)'
  fi
  printf 'summary: stop-unlist=%s delete=%s protected=%s ambiguous=%s mode=%s\n' \
    "$STOP_COUNT" "$DELETE_COUNT" "$PROTECTED_COUNT" "$AMBIGUOUS_COUNT" "$MODE"
  exit 0
fi

for i in "${!STOP_NAMES[@]}"; do
  print_project stop-unlist "${STOP_NAMES[$i]}" "${STOP_ROOTS[$i]}"
  run_cleanup "ddev stop --remove-data --omit-snapshot --unlist ${STOP_NAMES[$i]}" \
    ddev stop --remove-data --omit-snapshot --unlist "${STOP_NAMES[$i]}"
done
for i in "${!DELETE_NAMES[@]}"; do
  print_project delete "${DELETE_NAMES[$i]}" "${DELETE_ROOTS[$i]}"
  run_cleanup "ddev delete -Oy ${DELETE_NAMES[$i]}" ddev delete -Oy "${DELETE_NAMES[$i]}"
done
if [ -z "$WORKTREE" ]; then
  run_cleanup 'docker volume prune -f' docker volume prune -f
  run_cleanup 'docker image prune -f' docker image prune -f
  run_cleanup 'ddev delete images -y' ddev delete images -y
  run_cleanup 'docker system df' docker system df
fi
printf 'summary: stop-unlist=%s delete=%s protected=%s ambiguous=%s mode=%s\n' \
  "$STOP_COUNT" "$DELETE_COUNT" "$PROTECTED_COUNT" "$AMBIGUOUS_COUNT" "$MODE"
