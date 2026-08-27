#!/usr/bin/env bash
# Claude primary lifecycle hook for the away daemon's delivery guard.
#
# The daemon owns the private .primary generation and seeds it unknown on
# startup. These hooks update that exact live generation only from the
# lock-owning Claude primary session; outside away mode they are inert.
# fm-busy-lib.sh remains the owner of the semantic state format and trusted
# Claude source.
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
PAYLOAD=$(cat 2>/dev/null || true)

case "$NEW_STATE" in busy|idle) ;; *) exit 0 ;; esac
case "$EVENT" in ''|*[!A-Za-z0-9._-]*) exit 0 ;; esac
[ -f "$STATE/$PRIMARY_ID.busy-gen" ] || exit 0

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"

fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
fm_session_lock_owned_by_self "$STATE" || exit 0

"$SCRIPT_DIR/fm-busy-event.sh" apply "$STATE" "$PRIMARY_ID" "$NEW_STATE" \
  --current-gen --source claude-hook --event "$EVENT" >/dev/null 2>&1 || true
