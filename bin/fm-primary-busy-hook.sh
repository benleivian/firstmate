#!/usr/bin/env bash
# Claude primary lifecycle hook for the away daemon's delivery guard.
#
# The daemon owns the private .primary generation and seeds it unknown on
# startup. These hooks update that exact live generation while it exists;
# outside away mode they are inert. fm-busy-lib.sh remains the owner of the
# semantic state format and trusted Claude source.
#
# Usage: fm-primary-busy-hook.sh <busy|idle> <event-token>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PRIMARY_ID=.primary
NEW_STATE=${1:-}
EVENT=${2:-}

case "$NEW_STATE" in busy|idle) ;; *) exit 0 ;; esac
case "$EVENT" in ''|*[!A-Za-z0-9._-]*) exit 0 ;; esac
[ -f "$STATE/$PRIMARY_ID.busy-gen" ] || exit 0

"$SCRIPT_DIR/fm-busy-event.sh" apply "$STATE" "$PRIMARY_ID" "$NEW_STATE" \
  --current-gen --source claude-hook --event "$EVENT" >/dev/null 2>&1 || true
