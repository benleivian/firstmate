#!/usr/bin/env bash
# Focused behavior tests for the direct, opt-in Slack notification command.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NOTIFY="$ROOT/bin/fm-slack-notify.sh"
TMP_ROOT=$(fm_test_tmproot fm-slack-notify)
SERVER="$TMP_ROOT/server"
mkdir -p "$SERVER"
SERVER_PID=

cleanup_notify_test() {
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup_notify_test EXIT
trap 'cleanup_notify_test; exit 130' INT
trap 'cleanup_notify_test; exit 143' TERM

cat > "$SERVER/server.py" <<'PY'
import http.server
import json
import pathlib
import threading
import time

root = pathlib.Path(__file__).parent
lock = threading.Lock()

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode()
        with lock:
            with (root / "requests.jsonl").open("a") as out:
                out.write(json.dumps({"path": self.path, "body": body}) + "\n")
        if self.path == "/slow":
            time.sleep(8)
        response = b"bad" if self.path == "/bad" else b"ok"
        self.send_response(200)
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        try:
            self.wfile.write(response)
        except BrokenPipeError:
            pass

    def log_message(self, *args):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
(root / "port").write_text(str(server.server_port))
server.serve_forever()
PY
python3 "$SERVER/server.py" > "$SERVER/stdout" 2> "$SERVER/stderr" &
SERVER_PID=$!
for _ in $(seq 1 100); do
  [ -s "$SERVER/port" ] && break
  kill -0 "$SERVER_PID" 2>/dev/null || fail "capture server exited during startup"
  sleep 0.05
done
[ -s "$SERVER/port" ] || fail "capture server did not publish a port"
PORT=$(cat "$SERVER/port")
REQUESTS="$SERVER/requests.jsonl"

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state"
  chmod 700 "$home/config"
  printf '%s' "$home"
}

write_webhook() {
  local home=$1 path=$2
  printf 'http://127.0.0.1:%s%s\n' "$PORT" "$path" > "$home/config/slack-webhook-url"
  chmod 600 "$home/config/slack-webhook-url"
}

count_path() {
  local path=$1
  [ -f "$REQUESTS" ] || { printf '0'; return; }
  jq -s --arg path "$path" '[.[] | select(.path == $path)] | length' "$REQUESTS"
}

last_text() {
  local path=$1
  jq -rs --arg path "$path" '[.[] | select(.path == $path)] | last | .body | fromjson | .text' "$REQUESTS"
}

test_absent_configuration_is_inert() {
  local home out before after
  home=$(make_home absent)
  before=$(count_path /ok)
  out=$(printf '%s\n' 'Alpha needs a release decision.' | FM_HOME="$home" "$NOTIFY" send 2>&1)
  after=$(count_path /ok)
  [ -z "$out" ] || fail "absent configuration produced output: $out"
  [ "$before" = "$after" ] || fail "absent configuration sent a request"
  [ ! -e "$home/state/slack-alerts" ] || fail "direct notifier created deduplication state"
  pass "absent configuration is a silent no-op with no notification state"
}

test_setup_atomically_replaces_a_symlink() {
  local home outside mode
  home=$(make_home setup)
  outside="$home/outside-secret"
  printf 'outside unchanged\n' > "$outside"
  ln -s "$outside" "$home/config/slack-webhook-url"
  printf 'http://127.0.0.1:%s/setup\n' "$PORT" | \
    FM_HOME="$home" FM_SLACK_NOTIFY_ALLOW_LOOPBACK=1 "$NOTIFY" setup >/dev/null 2>&1 \
    || fail "setup rejected the local fake webhook"
  [ ! -L "$home/config/slack-webhook-url" ] || fail "setup retained the webhook symlink"
  [ "$(cat "$outside")" = 'outside unchanged' ] || fail "setup followed and overwrote the symlink target"
  mode=$(if [ "$(uname)" = Darwin ]; then stat -f %Lp "$home/config/slack-webhook-url"; else stat -c %a "$home/config/slack-webhook-url"; fi)
  [ "$mode" = 600 ] || fail "setup did not store the webhook with mode 0600"
  pass "setup atomically replaces an existing symlink with one private local secret"
}

test_direct_send_shapes_one_way_payload() {
  local home path before after text
  home=$(make_home success)
  path=/success
  write_webhook "$home" "$path"
  before=$(count_path "$path")
  printf '%s\n' 'Alpha is ready for your release approval.' | \
    FM_HOME="$home" FM_SLACK_NOTIFY_ALLOW_LOOPBACK=1 "$NOTIFY" send >/dev/null 2>&1
  after=$(count_path "$path")
  [ "$after" -eq $((before + 1)) ] || fail "direct send did not make exactly one request"
  text=$(last_text "$path")
  printf '%s' "$text" | grep -F 'Alpha is ready for your release approval.' >/dev/null \
    || fail "payload omitted the supplied concise captain-action message"
  printf '%s' "$text" | grep -F 'Notification only.' >/dev/null \
    || fail "payload omitted the notification-only boundary"
  printf '%s' "$text" | grep -F 'decisions, approvals, credentials, and instructions' >/dev/null \
    || fail "payload omitted trusted-channel return categories"
  pass "direct send posts one concise notification-only payload"
}

test_direct_send_has_no_deduplication() {
  local home path before after
  home=$(make_home duplicates)
  path=/duplicates
  write_webhook "$home" "$path"
  before=$(count_path "$path")
  for _ in 1 2; do
    printf '%s\n' 'Alpha still needs your decision.' | \
      FM_HOME="$home" FM_SLACK_NOTIFY_ALLOW_LOOPBACK=1 "$NOTIFY" send >/dev/null 2>&1
  done
  after=$(count_path "$path")
  [ "$after" -eq $((before + 2)) ] || fail "direct notifier unexpectedly added deduplication or event state"
  [ ! -e "$home/state/slack-alerts" ] || fail "direct notifier persisted event identity"
  pass "each explicit invocation is one attempt with no scanner or deduplication infrastructure"
}

test_failure_is_bounded_and_best_effort() {
  local home start elapsed out rc
  home=$(make_home timeout)
  write_webhook "$home" /slow
  start=$SECONDS
  out=$(printf '%s\n' 'Alpha needs your decision.' | \
    FM_HOME="$home" FM_SLACK_NOTIFY_ALLOW_LOOPBACK=1 "$NOTIFY" send 2>&1)
  rc=$?
  elapsed=$((SECONDS - start))
  [ "$rc" -eq 0 ] || fail "delivery failure blocked the normal escalation"
  [ "$elapsed" -lt 7 ] || fail "delivery exceeded its short bound (${elapsed}s)"
  printf '%s' "$out" | grep -F 'trusted-channel escalation still continues' >/dev/null \
    || fail "delivery failure lacked the generic local diagnostic"
  printf '%s' "$out" | grep -F "127.0.0.1:$PORT" >/dev/null \
    && fail "delivery diagnostic exposed the webhook"
  pass "delivery failure is bounded, generic, and best-effort"
}

test_explicit_harmless_test() {
  local home out text
  home=$(make_home test)
  write_webhook "$home" /test
  out=$(FM_HOME="$home" FM_SLACK_NOTIFY_ALLOW_LOOPBACK=1 "$NOTIFY" test 2>&1) \
    || fail "explicit setup test failed: $out"
  printf '%s' "$out" | grep -F 'test delivered' >/dev/null || fail "test did not report success"
  text=$(last_text /test)
  printf '%s' "$text" | grep -F 'No action is required.' >/dev/null \
    || fail "test message could be mistaken for a real escalation"
  pass "explicit setup test uses the local fake endpoint and requires no Slack credential"
}

test_absent_configuration_is_inert
test_setup_atomically_replaces_a_symlink
test_direct_send_shapes_one_way_payload
test_direct_send_has_no_deduplication
test_failure_is_bounded_and_best_effort
test_explicit_harmless_test
