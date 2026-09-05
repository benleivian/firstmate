#!/usr/bin/env bash
# fm-ddev-clean.sh - safely remove DDEV resources Firstmate and no-mistakes leave behind.
#
# Usage:
#   fm-ddev-clean.sh [--apply]
#   fm-ddev-clean.sh --worktree <path> [--apply]
#
# Dry-run is the default. With --worktree, delete only DDEV projects whose
# resolved approot is inside that worktree. Without it, first stop and unlist
# missing approots under ~/.no-mistakes/worktrees or ~/.treehouse/*/<slot>/*,
# then delete non-live projects under those roots.
# Docker volume prune, image prune, and DDEV image deletion are host-wide,
# dangling-only operations. It never uses -a/--all for cleanup.
# `state/*.meta` worktree= entries identify live treehouse worktrees in this home.
# Every ddev, docker, and JSON-parser call has FM_DDEV_CLEAN_TIMEOUT_SECS seconds
# (default 30); failed cleanup commands warn and do not stop later cleanup.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
TIMEOUT_SECS="${FM_DDEV_CLEAN_TIMEOUT_SECS:-30}"
APPLY=0
WORKTREE=
MODE=fleet

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  sed -n '2,16s/^# \{0,1\}//p' "$0"
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
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

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
  RUN_OUTPUT=$(fm_run_timed "$TIMEOUT_SECS" "$@" 2>&1) || RUN_STATUS=$?
  RUN_STATUS=${RUN_STATUS:-0}
  return "$RUN_STATUS"
}

run_cleanup() {
  local label=$1
  shift
  RUN_STATUS=0
  if run_capture "$@"; then
    printf 'changed: %s\n' "$label"
  else
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

RUN_STATUS=0
if ! run_capture ddev list --json-output; then
  printf 'fm-ddev-clean: ddev list failed (exit %s): %s\n' "$RUN_STATUS" "$RUN_OUTPUT" >&2
  exit 1
fi
PROJECTS=$(FM_DDEV_JSON="$RUN_OUTPUT" fm_run_timed "$TIMEOUT_SECS" python3 -c '
import json, os, os.path
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
    if not name or not approot:
        raise ValueError("ddev project lacks name or approot")
    print("%s\t%s\t%s" % (name, os.path.realpath(approot), project.get("status") or ""))
') || {
  echo "fm-ddev-clean: could not parse ddev list JSON" >&2
  exit 1
}

DELETE_NAMES=()
STOP_NAMES=()
DELETE_COUNT=0
STOP_COUNT=0
# shellcheck disable=SC2034 # status is retained from DDEV's documented raw shape.
while IFS=$'\t' read -r name approot status; do
  [ -n "$name" ] || continue
  if [ -n "$WORKTREE" ]; then
    if path_within "$approot" "$WORKTREE"; then
      DELETE_NAMES+=("$name")
      DELETE_COUNT=$((DELETE_COUNT + 1))
    fi
  elif is_managed_root "$approot"; then
    if [ ! -d "$approot" ]; then
      STOP_NAMES+=("$name")
      STOP_COUNT=$((STOP_COUNT + 1))
    elif ! is_live_worktree "$approot"; then
      DELETE_NAMES+=("$name")
      DELETE_COUNT=$((DELETE_COUNT + 1))
    fi
  fi
done <<EOF
$PROJECTS
EOF

if [ "$APPLY" -ne 1 ]; then
  for name in "${STOP_NAMES[@]:-}"; do
    [ -n "$name" ] || continue
    printf 'would: ddev stop --remove-data --unlist %s\n' "$name"
  done
  for name in "${DELETE_NAMES[@]:-}"; do
    [ -n "$name" ] || continue
    printf 'would: ddev delete -Oy %s\n' "$name"
  done
  if [ -z "$WORKTREE" ]; then
    echo 'would: docker volume prune -f (host-wide, dangling-only)'
    echo 'would: docker image prune -f (host-wide, dangling-only)'
    echo 'would: ddev delete images -y (host-wide, dangling-only)'
  fi
  printf 'summary: stop-unlist=%s delete=%s mode=%s\n' \
    "$STOP_COUNT" "$DELETE_COUNT" "$MODE"
  exit 0
fi

for name in "${STOP_NAMES[@]:-}"; do
  [ -n "$name" ] || continue
  run_cleanup "ddev stop --remove-data --unlist $name" ddev stop --remove-data --unlist "$name"
done
for name in "${DELETE_NAMES[@]:-}"; do
  [ -n "$name" ] || continue
  run_cleanup "ddev delete -Oy $name" ddev delete -Oy "$name"
done
if [ -z "$WORKTREE" ]; then
  run_cleanup 'docker volume prune -f' docker volume prune -f
  run_cleanup 'docker image prune -f' docker image prune -f
  run_cleanup 'ddev delete images -y' ddev delete images -y
  run_cleanup 'docker system df' docker system df
fi
printf 'summary: stop-unlist=%s delete=%s mode=%s\n' \
  "$STOP_COUNT" "$DELETE_COUNT" "$MODE"
