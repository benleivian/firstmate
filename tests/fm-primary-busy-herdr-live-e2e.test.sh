#!/usr/bin/env bash
# Live Claude primary semantic-busy guard (live-harness-optin family).
# Run explicitly after a Herdr or Claude upgrade to refresh the corresponding
# runtime-backend verification entry.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

if [ "${FM_PRIMARY_BUSY_HERDR_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_PRIMARY_BUSY_HERDR_LIVE=1 to run the live Claude primary busy guard"
  exit 0
fi

command -v herdr >/dev/null 2>&1 || fail "FM_PRIMARY_BUSY_HERDR_LIVE=1 but herdr is not installed"
command -v jq >/dev/null 2>&1 || fail "FM_PRIMARY_BUSY_HERDR_LIVE=1 but jq is not installed"
command -v claude >/dev/null 2>&1 || fail "FM_PRIMARY_BUSY_HERDR_LIVE=1 but Claude Code is not installed"
[ -x "$LAB_HELPER" ] || fail "FM_PRIMARY_BUSY_HERDR_LIVE=1 but the Herdr lab helper is unavailable"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name primary-busy-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-primary-busy-live.XXXXXX")
FIXTURE="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"
STATE="$FIXTURE/state"
mkdir -p "$FIXTURE/.claude" "$STATE" "$FAKEBIN"

cleanup() {
  local rc=$?
  trap - EXIT
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

cp -R "$ROOT/bin" "$FIXTURE/bin"
cp "$ROOT/AGENTS.md" "$FIXTURE/AGENTS.md"
jq '{hooks:{UserPromptSubmit:.hooks.UserPromptSubmit,Stop:.hooks.Stop,StopFailure:.hooks.StopFailure,SessionEnd:.hooks.SessionEnd}}' \
  "$ROOT/.claude/settings.json" > "$FIXTURE/.claude/settings.json"
git init -q "$FIXTURE"
git -C "$FIXTURE" add AGENTS.md bin .claude/settings.json
git -C "$FIXTURE" -c user.name=fmtest -c user.email=fmtest@example.invalid \
  commit -q -m init

cat > "$FIXTURE/run-claude.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
exec claude --dangerously-skip-permissions
SH
chmod +x "$FIXTURE/run-claude.sh"

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || exit 97
  args=("\${args[@]:0:\$((n-2))}")
else
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
WS_JSON=$(lab workspace create --cwd "$FIXTURE" --label fm-primary-busy --no-focus) \
  || fail "could not create the isolated primary-busy workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
TARGET="$SESSION:$PANE"
CLAUDE_VER=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')

"$FIXTURE/bin/fm-busy-event.sh" arm "$STATE" .primary \
  --state unknown --source fm-recovery --event daemon-start >/dev/null
lab pane run "$PANE" "cd '$FIXTURE' && FM_HOME='$FIXTURE' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false '$FIXTURE/run-claude.sh'" >/dev/null \
  || fail "could not launch Claude Code ($CLAUDE_VER) in the isolated pane"

ready=0
i=0
composer=unknown
trust_confirmed=0
bypass_confirmed=0
while [ "$i" -lt 60 ]; do
  composer=$(fm_backend_herdr_composer_state "$TARGET" 2>/dev/null)
  [ "$composer" = empty ] && ready=1 && break
  if [ "$trust_confirmed" = 0 ] || [ "$bypass_confirmed" = 0 ]; then
    screen=$(lab pane read "$PANE" --source recent --lines 80 2>/dev/null || true)
    if [ "$bypass_confirmed" = 0 ] \
      && printf '%s' "$screen" | grep -F 'Yes, I accept' >/dev/null; then
      lab pane send-keys "$PANE" down enter >/dev/null \
        || fail "could not accept bypass mode for the isolated fixture"
      bypass_confirmed=1
    elif [ "$trust_confirmed" = 0 ] \
      && printf '%s' "$screen" | grep -F 'Yes, I trust this folder' >/dev/null; then
      lab pane send-keys "$PANE" enter >/dev/null \
        || fail "could not confirm trust for the test-created fixture"
      trust_confirmed=1
    fi
  fi
  i=$((i + 1))
  sleep 1
done
if [ "$ready" != 1 ]; then
  lab pane read "$PANE" --source recent --lines 80 >&2 || true
  fail "Claude Code ($CLAUDE_VER) never reached an empty composer (last verdict: $composer)"
fi

TOKEN="BACKGROUND_READY_$$_$RANDOM"
PROMPT="Use the Bash tool exactly once to run sleep 120 as a tracked background task. After the tool reports its background task id, reply with exactly $TOKEN and take no more actions."
[ "$(fm_backend_herdr_send_text_submit "$TARGET" "$PROMPT" 3 0.4 0.4)" = empty ] \
  || fail "could not submit the tracked-background-shell reproduction prompt"

reproduced=0
i=0
while [ "$i" -lt 90 ]; do
  screen=$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null || true)
  semantic=$(fm_busy_classify herdr "$TARGET" claude .primary "$STATE")
  native=$(fm_backend_herdr_busy_state "$TARGET" 2>/dev/null || printf unknown)
  occurrences=$(printf '%s\n' "$screen" | grep -F -c "$TOKEN" || true)
  if [ "$occurrences" -ge 2 ] \
    && [ "$semantic" = "idle claude-hook" ] && [ "$native" = busy ]; then
    reproduced=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$reproduced" = 1 ] \
  || fail "Claude Code ($CLAUDE_VER) on $HERDR_VER did not reproduce semantic idle with native busy"

export FM_HOME="$FIXTURE"
export FM_STATE_OVERRIDE="$STATE"
# shellcheck source=bin/fm-supervise-daemon.sh
. "$ROOT/bin/fm-supervise-daemon.sh"
export FM_DAEMON_PRIMARY_BUSY_READY=1
export FM_DAEMON_PRIMARY_HARNESS=claude
export FM_SUPERVISOR_BACKEND=herdr
export FM_SUPERVISOR_TARGET="$TARGET"
: > "$STATE/.afk"
escalate_add "$STATE" "live-verification: done: semantic idle outranks tracked-shell native busy"
if ! escalate_flush "$STATE"; then
  printf 'semantic=%s native=%s composer=%s\n' \
    "$(fm_busy_classify herdr "$TARGET" claude .primary "$STATE")" \
    "$(fm_backend_herdr_busy_state "$TARGET" 2>/dev/null || printf unknown)" \
    "$(fm_backend_herdr_composer_state "$TARGET" 2>/dev/null || printf unknown)" >&2
  lab pane read "$PANE" --source recent --lines 80 >&2 || true
  fail "the queued escalation did not deliver through the semantic idle guard"
fi
[ ! -s "$STATE/.subsuper-escalations" ] \
  || fail "successful semantic-idle delivery left its escalation buffered"

pass "live Claude primary busy guard: $CLAUDE_VER on $HERDR_VER reproduces native busy at semantic idle and delivers in an isolated named lab"
