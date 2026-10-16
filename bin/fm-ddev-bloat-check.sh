#!/usr/bin/env bash
# fm-ddev-bloat-check.sh - daily Docker volume bloat check that only recommends /ddevclean.
#
# Usage:
#   fm-ddev-bloat-check.sh [check]
#   fm-ddev-bloat-check.sh arm
#   fm-ddev-bloat-check.sh disarm
#   fm-ddev-bloat-check.sh --help
#
# `check` evaluates at most once every 86400 seconds; polls inside that interval
# read only state/.ddev-bloat-check and stay silent.
# A due evaluation runs one bounded `docker system df -v` and compares the
# ddev-global-cache volume and the sum of all local volumes against thresholds:
#   ddev-global-cache-gb=15   local-volumes-gb=60   (decimal GB, Docker's units)
# Optional config/ddev-bloat-thresholds overrides either with one key=value line;
# blank and # lines are ignored, and any other line is reported as invalid.
# It prints one ddev-bloat: line, which the watcher turns into a check wake, only
# when the set of crossed thresholds (or a config problem) differs from the last
# reported set; it stays silent while that set is unchanged and re-arms once
# usage falls back under every threshold.
# Docker being absent, stopped, or slow is silent and retried on the next poll.
# It never deletes, prunes, or stops anything.
#
# `arm` writes state/ddev-bloat.check.sh and binds its bytes with
# fm-check-register.sh so the existing watcher slow-check cadence runs it.
# `disarm` removes the shim, its trust binding, and the record.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CHECK_ID=ddev-bloat
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
RECORD="$STATE/.ddev-bloat-check"
INTERVAL=86400

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

fail() {
  printf 'fm-ddev-bloat-check: %s\n' "$1" >&2
  exit 1
}

record_value() {  # <key>
  [ -f "$RECORD" ] || return 0
  awk -v key="$1" '$1 == key { sub(/^[^ ]+ ?/, ""); print; exit }' "$RECORD"
}

run_check() {
  local now last cache_gb=15 volumes_gb=60 invalid='' line key value sizes cache_bytes total_bytes
  local found='' keys='' previous tmp
  case "${FM_DDEV_BLOAT_NOW:-}" in
    ''|*[!0-9]*) now=$(date +%s) ;;
    *) now=$FM_DDEV_BLOAT_NOW ;;
  esac
  last=$(record_value last_eval)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $((now - last)) -ge "$INTERVAL" ] || return 0

  if [ -f "$CONFIG_DIR/ddev-bloat-thresholds" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|'#'*) continue ;; esac
      key=${line%%=*}
      value=${line#*=}
      case "$key=$value" in
        ddev-global-cache-gb=[1-9]*|local-volumes-gb=[1-9]*)
          case "$value" in *[!0-9]*) invalid=1; continue ;; esac
          if [ "$key" = ddev-global-cache-gb ]; then cache_gb=$value; else volumes_gb=$value; fi
          ;;
        *) invalid=1 ;;
      esac
    done < "$CONFIG_DIR/ddev-bloat-thresholds"
  fi

  command -v docker >/dev/null 2>&1 || return 0
  sizes=$(fm_run_timed 20 docker system df -v --format '{{json .}}' 2>/dev/null | python3 -c '
import json, re, sys
units = {"B": 1, "kB": 1e3, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12, "PB": 1e15}
def size(text):
    match = re.fullmatch(r"([0-9.]+)\s*([A-Za-z]+)", str(text).strip())
    if not match or match.group(2) not in units:
        return 0
    return int(float(match.group(1)) * units[match.group(2)])
volumes = json.load(sys.stdin)["Volumes"] or []
cache = sum(size(v["Size"]) for v in volumes if v.get("Name") == "ddev-global-cache")
print(cache, sum(size(v["Size"]) for v in volumes))
' 2>/dev/null) || return 0
  read -r cache_bytes total_bytes <<< "$sizes"
  case "$cache_bytes$total_bytes" in ''|*[!0-9]*) return 0 ;; esac

  if [ "$cache_bytes" -gt $((cache_gb * 1000000000)) ]; then
    found="$found; ddev-global-cache is $(gb "$cache_bytes") GB (threshold $cache_gb GB)"
    keys="$keys cache"
  fi
  if [ "$total_bytes" -gt $((volumes_gb * 1000000000)) ]; then
    found="$found; local Docker volumes total $(gb "$total_bytes") GB (threshold $volumes_gb GB)"
    keys="$keys volumes"
  fi
  if [ -n "$invalid" ]; then
    found="$found; config/ddev-bloat-thresholds has an invalid line that was ignored"
    keys="$keys config"
  fi
  previous=$(record_value reported)
  if [ -n "$keys" ] && [ "$keys" != "$previous" ]; then
    printf 'ddev-bloat: %s; run /ddevclean to preview a cleanup (nothing was deleted)\n' "${found#; }"
  fi
  tmp=$(mktemp "$STATE/.ddev-bloat-check.XXXXXX") || return 0
  if ! printf 'last_eval %s\nreported %s\n' "$now" "$keys" > "$tmp" || ! mv -f -- "$tmp" "$RECORD"; then
    rm -f -- "$tmp"
  fi
}

gb() {
  awk -v b="$1" 'BEGIN { printf "%.1f", b / 1e9 }'
}

arm() {
  local home tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail "state directory is unavailable"
  home=$(cd -P -- "$FM_HOME" 2>/dev/null && pwd -P) || fail "cannot resolve FM_HOME $FM_HOME"
  tmp=$(umask 077; mktemp "$STATE/.ddev-bloat-shim.XXXXXX") || fail "check shim path is unavailable"
  if ! printf '#!/usr/bin/env bash\nexport FM_HOME=%q\nexec %q check\n' "$home" "$SCRIPT_DIR/fm-ddev-bloat-check.sh" > "$tmp" \
    || ! chmod 0700 "$tmp" || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    fail "could not write the check shim"
  fi
  if ! FM_HOME="$home" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null; then
    rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
    fail "could not register the check shim"
  fi
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  check) [ "$#" -le 1 ] || { usage >&2; exit 2; }; run_check ;;
  arm) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; arm ;;
  disarm)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD"
    printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
    ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
