#!/usr/bin/env bash
# Send one direct, bounded Slack Incoming Webhook notification.
#
# Usage:
#   fm-slack-notify.sh setup
#   printf '%s\n' '<concise safe captain-action message>' | fm-slack-notify.sh send
#   fm-slack-notify.sh test
#   fm-slack-notify.sh --help
#
# In Slack, create an app, enable Incoming Webhooks, and add one webhook for the
# chosen private channel. Keep its URL out of chat and run `setup` locally.
# `setup` prompts without echo and atomically stores the webhook in the current
# Firstmate home's gitignored config/slack-webhook-url with mode 0600.
# `send` is best-effort: absent configuration is a silent no-op, and delivery
# failure prints one generic local diagnostic but returns success so the normal
# trusted-channel escalation always continues. It accepts one plain-text line,
# adds the notification-only boundary, attempts one POST, and never retries.
# `test` sends one fixed harmless setup message and returns nonzero on failure.
#
# Slack is outbound notification only. Decisions, approvals, credentials, and
# instructions must return through the trusted Firstmate captain channel.
# Remove config/slack-webhook-url to disable notifications. Re-run `setup` to
# rotate locally, then revoke the old webhook in Slack.
#
# Test-only environment:
#   FM_SLACK_NOTIFY_ALLOW_LOOPBACK=1 permits an http://127.0.0.1:<port>/ endpoint.
set +x
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SECRET="$CONFIG/slack-webhook-url"
WEBHOOK=

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

diag() {
  printf 'slack-notify: %s\n' "$1" >&2
}

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

webhook_valid() {
  local value=$1 slack_re loopback_re
  slack_re='^https://hooks\.slack\.com/services/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+$'
  loopback_re='^http://127\.0\.0\.1:[0-9]+/[A-Za-z0-9._/?&%-]*$'
  [[ "$value" =~ $slack_re ]] && return 0
  [ "${FM_SLACK_NOTIFY_ALLOW_LOOPBACK:-}" = 1 ] \
    && [[ "$value" =~ $loopback_re ]]
}

setup_webhook() {
  local value tmp
  if [ -e "$CONFIG" ] || [ -L "$CONFIG" ]; then
    [ -d "$CONFIG" ] && [ ! -L "$CONFIG" ] || {
      diag 'config must be a non-symlink directory'
      return 1
    }
  else
    mkdir -m 700 -p "$CONFIG" 2>/dev/null || {
      diag 'could not create the private config directory'
      return 1
    }
  fi
  if [ -d "$SECRET" ] && [ ! -L "$SECRET" ]; then
    diag 'webhook path must not be a directory'
    return 1
  fi
  printf 'Paste Slack Incoming Webhook URL: ' >&2
  IFS= read -r -s value || true
  printf '\n' >&2
  webhook_valid "$value" || {
    diag 'the webhook URL is not an accepted Slack Incoming Webhook'
    return 1
  }
  tmp=$(mktemp "$CONFIG/.slack-webhook-url.XXXXXX" 2>/dev/null) || {
    diag 'could not create a private temporary file'
    return 1
  }
  chmod 600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  if ! printf '%s\n' "$value" > "$tmp" || ! mv -f "$tmp" "$SECRET"; then
    rm -f "$tmp"
    diag 'could not store the webhook'
    return 1
  fi
  chmod 600 "$SECRET" 2>/dev/null || {
    diag 'could not secure the webhook file'
    return 1
  }
  printf '%s\n' 'slack-notify: configured'
}

load_webhook() {
  local mode extra=
  WEBHOOK=
  if [ ! -e "$SECRET" ] && [ ! -L "$SECRET" ]; then
    return 2
  fi
  [ -d "$CONFIG" ] && [ ! -L "$CONFIG" ] \
    && [ -f "$SECRET" ] && [ ! -L "$SECRET" ] || return 1
  mode=$(file_mode "$SECRET") || return 1
  [ "$mode" = 600 ] || return 1
  IFS= read -r WEBHOOK < "$SECRET" || true
  if IFS= read -r extra < <(tail -n +2 "$SECRET" 2>/dev/null) || [ -n "$extra" ]; then
    return 1
  fi
  [ -n "$WEBHOOK" ] && webhook_valid "$WEBHOOK"
}

safe_message() {
  local message=$1
  [ -n "$message" ] && [ "${#message}" -le 280 ] || return 1
  case "$message" in
    *[$'\001'-$'\037'$'\177']*) return 1 ;;
  esac
  return 0
}

payload_for() {
  local message=$1 text
  text=$(printf '%s\n\nNotification only. Return decisions, approvals, credentials, and instructions through the trusted Firstmate captain channel.' "$message")
  printf '%s' "$text" | jq -Rs '{text:.}'
}

post_payload() {
  local payload=$1 response code rc body proto='=https'
  command -v curl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  case "$WEBHOOK" in http://127.0.0.1:*) proto='=http,https' ;; esac
  response=$(mktemp "${TMPDIR:-/tmp}/fm-slack-notify.XXXXXX" 2>/dev/null) || return 1
  chmod 600 "$response" 2>/dev/null || { rm -f "$response"; return 1; }
  code=$(printf '%s' "$payload" | curl --disable \
    --silent \
    --request POST \
    --header 'Content-Type: application/json; charset=utf-8' \
    --data-binary @- \
    --output "$response" \
    --write-out '%{http_code}' \
    --connect-timeout 2 \
    --max-time 5 \
    --max-redirs 0 \
    --max-filesize 1024 \
    --proto "$proto" \
    --config /dev/fd/3 \
    3< <(printf 'url = "%s"\n' "$WEBHOOK") \
    2>/dev/null)
  rc=$?
  body=$(cat "$response" 2>/dev/null || true)
  rm -f "$response"
  [ "$rc" -eq 0 ] && [ "$code" = 200 ] && [ "$body" = ok ]
}

send_message() {
  local message= payload load_rc
  load_webhook
  load_rc=$?
  case "$load_rc" in
    0) ;;
    2) return 0 ;;
    *) diag 'webhook configuration is unsafe or invalid; notification skipped'; return 0 ;;
  esac
  IFS= read -r message || true
  safe_message "$message" || {
    diag 'message must be one non-empty plain-text line of at most 280 characters'
    return 0
  }
  command -v jq >/dev/null 2>&1 || {
    diag 'delivery dependency unavailable; notification skipped'
    return 0
  }
  payload=$(payload_for "$message") || {
    diag 'could not prepare the notification; notification skipped'
    return 0
  }
  post_payload "$payload" || diag 'delivery failed; the trusted-channel escalation still continues'
  return 0
}

test_message() {
  local payload load_rc
  load_webhook
  load_rc=$?
  case "$load_rc" in
    0) ;;
    2) diag 'not configured'; return 1 ;;
    *) diag 'webhook configuration is unsafe or invalid'; return 1 ;;
  esac
  command -v jq >/dev/null 2>&1 || { diag 'delivery dependency unavailable'; return 1; }
  payload=$(payload_for 'Firstmate Slack setup test. No action is required.') || return 1
  if post_payload "$payload"; then
    printf '%s\n' 'slack-notify: test delivered'
    return 0
  fi
  diag 'test delivery failed'
  return 1
}

umask 077
case "${1:-}" in
  setup)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    setup_webhook
    ;;
  send)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    send_message
    ;;
  test)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    test_message
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
