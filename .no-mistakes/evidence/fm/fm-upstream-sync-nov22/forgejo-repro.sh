#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must record pr= and any available pr_head= into the task's meta so
# fm-teardown.sh's landed-check has a PR reference to verify against, even on
# repos with no PR CI where the usual "checks green" fm-pr-check.sh trigger
# never fires.
#
# The test_* functions below name the covered merge, refusal, live-head,
# away-authority, outcome-publication, and recovery behavior directly.
set -u

# shellcheck source=tests/lib.sh
. "$PWD/tests/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)
BASE_PATH=$PATH

# The GitLab fixture. A placeholder host that resolves nowhere, and a namespace
# deeper than one group, because a GitLab project has no owner/repository pair.
MR_HOST=gitlab.example
MR_PATH=group/subgroup/project
MR_PROJECT_URL="https://$MR_HOST/$MR_PATH"
MR_URL="$MR_PROJECT_URL/-/merge_requests/7"
MR_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
MR_STALE_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# The Forgejo fixture. A placeholder host that resolves nowhere, exactly two
# path segments (owner/repository, no subgroup nesting), and the plural
# "pulls" route Forgejo/Gitea use.
FJ_HOST=forgejo.example
FJ_OWNER=fixture
FJ_REPO=fixture-repo
FJ_LOGIN=fm-fixture
FJ_URL="https://$FJ_HOST/$FJ_OWNER/$FJ_REPO/pulls/9"
FJ_HEAD=cccccccccccccccccccccccccccccccccccccccc
FJ_STALE_HEAD=dddddddddddddddddddddddddddddddddddddddd

JQ_BIN=$(command -v jq) || fail "these tests read glab's JSON with the real jq, which was not found"
REAL_MV=$(command -v mv) || fail "these tests need mv to simulate a failed poll publish"

# Build a fresh sandbox for one test case: a state dir with task metadata and a
# directory for its forge-command mocks. Echoes the case directory.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/home/data" "$case_dir/home/config" "$fakebin"
  fm_git_init_commit "$case_dir/wt"
  git -C "$case_dir/wt" update-ref refs/remotes/origin/main "$(git -C "$case_dir/wt" rev-parse HEAD)"
  fm_test_tasks_toml "$case_dir/home/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' \
    > "$case_dir/home/data/backlog.md"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  printf '%s\n' \
    'state=MERGED' \
    'merged=true' \
    'queued=false' \
    'base=main' > "$case_dir/github-outcome"
  : > "$case_dir/github-rules"
  # The base branch the forge reports by default: unprotected, with no ruleset
  # rule, so nothing is required unless a case says otherwise.
  write_github_required "$case_dir"
  : > "$case_dir/gh.log"
  # The worktree is a git copy whose HEAD is on a remote-tracking ref, as a
  # pushed ship task's is, so fm-pr-check.sh's named-head gate accepts it when
  # the forge supplies no head (GitLab). No project clone exists on disk.
  printf '%s\n' "$case_dir"
}

# The base branch's required checks as GitHub reports them: the classic branch
# protection summary on the branch, and the active ruleset rules for it. Each
# name is given as classic:<context> or ruleset:<context>; with no names the
# branch is unprotected and has no rules. Args: case_dir [kind:name]...
write_github_required() {
  local case_dir=$1 spec contexts='' checks='' rules='' protected=false
  shift
  for spec in "$@"; do
    case "$spec" in
      classic:*)
        protected=true
        contexts="${contexts:+$contexts,}\"${spec#classic:}\""
        checks="${checks:+$checks,}{\"context\":\"${spec#classic:}\",\"app_id\":null}"
        ;;
      ruleset:*)
        rules="${rules:+$rules,}{\"type\":\"required_status_checks\",\"parameters\":{\"required_status_checks\":[{\"context\":\"${spec#ruleset:}\"}]}}"
        ;;
      *) fail "write_github_required: unknown spec '$spec'" ;;
    esac
  done
  printf '{"name":"main","protected":%s,"protection":{"enabled":%s,"required_status_checks":{"enforcement_level":"%s","contexts":[%s],"checks":[%s]}}}\n' \
    "$protected" "$protected" "$([ "$protected" = true ] && echo non_admins || echo off)" "$contexts" "$checks" \
    > "$case_dir/github-branch.json"
  printf '[{"type":"deletion"}%s]\n' "${rules:+,$rules}" > "$case_dir/github-required-rules.json"
}

# Live GitHub JSON for the pre-merge verify, plus gh-axi for the
# post-merge fallback view. Merge itself is `gh pr merge --match-head-commit`.
# Args: case_dir head_sha
write_github_live_json() {
  local case_dir=$1 head=$2
  printf '%s\n' "$head" > "$case_dir/github-head"
  cat > "$case_dir/github-view.json" <<JSON
{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"$head","baseRefName":"main","statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}
JSON
}

write_github_red_json() {
  local case_dir=$1 head=$2 name=$3
  printf '%s\n' "$head" > "$case_dir/github-head"
  cat > "$case_dir/github-view.json" <<JSON
{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"$head","baseRefName":"main","statusCheckRollup":[{"__typename":"CheckRun","name":"$name","status":"COMPLETED","conclusion":"FAILURE"}]}
JSON
}

# One CheckRun rollup entry the way GitHub reports it. A conclusion or timestamp
# of "-" is emitted as JSON null. Args: name status conclusion [startedAt]
# [completedAt]
check_run() {
  local name=$1 status=$2 conclusion=$3 started=${4:--} completed=${5:-${4:--}}
  local conclusion_json='null' started_json='null' completed_json='null'
  [ "$conclusion" = - ] || conclusion_json="\"$conclusion\""
  [ "$started" = - ] || started_json="\"$started\""
  [ "$completed" = - ] || completed_json="\"$completed\""
  printf '{"__typename":"CheckRun","name":"%s","status":"%s","conclusion":%s,"startedAt":%s,"completedAt":%s}' \
    "$name" "$status" "$conclusion_json" "$started_json" "$completed_json"
}

status_context() {
  local name=$1 state=$2
  printf '{"__typename":"StatusContext","context":"%s","state":"%s"}' "$name" "$state"
}

# Live GitHub JSON whose rollup holds the given entries verbatim, so a test can
# put several runs of one check name at the same head the way GitHub does after
# it cancels a pull request's in-flight run and re-triggers it. mergeStateStatus
# stays CLEAN because that is what GitHub reports for exactly this case.
# Args: case_dir head_sha <rollup-entry-json>...
write_github_rollup_json() {
  local case_dir=$1 head=$2 entry rollup=''
  shift 2
  for entry in "$@"; do
    rollup="${rollup:+$rollup,}$entry"
  done
  printf '%s\n' "$head" > "$case_dir/github-head"
  cat > "$case_dir/github-view.json" <<JSON
{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"$head","baseRefName":"main","statusCheckRollup":[$rollup]}
JSON
}

assert_logged_gh_merge() {
  local case_dir=$1 number=$2 repo=$3 head line extra=
  shift 3
  head=$(cat "$case_dir/github-head")
  [ "$#" -eq 0 ] || extra=" $*"
  line="pr merge $number --repo $repo --match-head-commit $head$extra"
  grep -qxF "$line" "$case_dir/gh.log" \
    || fail "expected gh merge line: $line"$'\n'"got: $(grep '^pr merge ' "$case_dir/gh.log" || true)"
}

add_gh_mocks() {
  local case_dir=$1 head=$2
  write_github_live_json "$case_dir" "$head"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    [ "$#" -eq 5 ] && [ "${4:-}" = --repo ] || exit 2
    printf 'pull_request:\n  number: %s\n  state: %s\n' "$3" "${FM_TEST_GH_MERGE_STATE:-merged}"
    ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *statusCheckRollup*)
        if [ -f "$FM_TEST_GH_PR_COMMITS.next-head" ]; then
          next_head=$(cat "$FM_TEST_GH_PR_COMMITS.next-head")
          printf '%s\n' "$next_head" > "$FM_TEST_GH_HEAD"
          jq --arg head "$next_head" '.headRefOid = $head' "$FM_TEST_GH_VIEW_JSON" > "$FM_TEST_GH_VIEW_JSON.next"
          mv "$FM_TEST_GH_VIEW_JSON.next" "$FM_TEST_GH_VIEW_JSON"
          jq -n --arg head "$next_head" '[{sha: $head, parents: [{sha: "parent"}, {sha: "upstream"}]}]' > "$FM_TEST_GH_PR_COMMITS"
          rm "$FM_TEST_GH_PR_COMMITS.next-head"
        fi
        view_json=$FM_TEST_GH_VIEW_JSON
        if [ -f "${FM_TEST_GH_UPDATE_VIEW:-}" ] && [ -f "${FM_TEST_GH_UPDATE_DONE:-}" ]; then
          view_json=$FM_TEST_GH_UPDATE_VIEW
        fi
        if [ -n "${FM_TEST_GH_MERGEABLE_SEQUENCE:-}" ]; then
          call_n=$(( $(cat "$FM_TEST_GH_MERGEABLE_CALLS" 2>/dev/null || echo 0) + 1 ))
          printf '%s\n' "$call_n" > "$FM_TEST_GH_MERGEABLE_CALLS"
          call_m=$(sed -n "${call_n}p" "$FM_TEST_GH_MERGEABLE_SEQUENCE")
          [ -n "$call_m" ] || call_m=$(tail -n1 "$FM_TEST_GH_MERGEABLE_SEQUENCE")
          # An optional second word overrides the first check's conclusion.
          read -r call_m call_c <<< "$call_m"
          call_h=
          view_dir=$(dirname "$FM_TEST_GH_VIEW_JSON")
          if [ -f "$view_dir/github-head-by-call" ]; then
            call_h=$(sed -n "${call_n}p" "$view_dir/github-head-by-call")
          fi
          jq -c --arg m "$call_m" --arg c "${call_c:-}" --arg h "$call_h" \
            '.mergeable = $m | if $h != "" then .headRefOid = $h else . end | if $c != "" then .statusCheckRollup[0].conclusion = $c else . end' \
            "$view_json"
        else
          cat "$view_json"
        fi
        if [ -f "${FM_TEST_GH_UPDATE_VIEW:-}" ] && [ -f "${FM_TEST_GH_UPDATE_DONE:-}" ] \
          && [ -f "${FM_TEST_GH_UPDATE_FINAL_VIEW:-}" ]; then
          cp "$FM_TEST_GH_UPDATE_FINAL_VIEW" "$FM_TEST_GH_UPDATE_VIEW"
        fi
        if [ -f "${FM_TEST_AWAY_RECORD_AFTER_VIEW:-}" ]; then
          if [ -s "${FM_TEST_AWAY_RECORD_AFTER_VIEW}" ]; then
            cp "$FM_TEST_AWAY_RECORD_AFTER_VIEW" "$FM_STATE_OVERRIDE/.afk-contract"
          else
            rm -f "$FM_STATE_OVERRIDE/.afk-contract"
          fi
        fi
        view_dir=$(dirname "$FM_TEST_GH_VIEW_JSON")
        if [ -f "$view_dir/github-head-after-view" ]; then
          cp "$view_dir/github-head-after-view" "$view_dir/github-server-head"
          rm -f "$view_dir/github-head-after-view"
        fi
        exit 0
        ;;
      *headRefOid*)
        cat "$FM_TEST_GH_HEAD"
        exit 0
        ;;
      *isDraft*)
        cat "$FM_TEST_GH_VIEW_JSON"
        exit 0
        ;;
      *" --json title,body "*)
        [ -f "${FM_TEST_GH_TEXT_JSON:-}" ] || exit 1
        cat "$FM_TEST_GH_TEXT_JSON"
        exit 0
        ;;
    esac
    ;;
  "pr merge")
    [ -z "${FM_TEST_GH_MERGE_ARGS:-}" ] || printf '%s\0' "$@" > "$FM_TEST_GH_MERGE_ARGS"
    if [ -n "${FM_TEST_META_AT_MERGE:-}" ] && [ -f "${FM_STATE_OVERRIDE:-}/task-x1.meta" ]; then
      cat "$FM_STATE_OVERRIDE/task-x1.meta" > "$FM_TEST_META_AT_MERGE"
    fi
    # The forge call runs inside the merge's critical section, so a real
    # away-record change attempted from here is the TOCTOU itself: whatever
    # happens to it happens between the authority read and the merge.
    if [ -x "${FM_TEST_AWAY_MUTATE_AT_MERGE:-}" ]; then
      away_rc=0
      "$FM_TEST_AWAY_MUTATE_AT_MERGE" > "$FM_TEST_AWAY_MUTATE_OUT" 2>&1 || away_rc=$?
      printf '%s\n' "$away_rc" > "$FM_TEST_AWAY_MUTATE_RC"
      "$FM_TEST_ROOT/bin/fm-afk-contract.sh" words \
        > "$FM_TEST_AWAY_WORDS_AT_MERGE" 2>/dev/null \
        || printf 'no-live-record\n' > "$FM_TEST_AWAY_WORDS_AT_MERGE"
    fi
    view_dir=$(dirname "$FM_TEST_GH_VIEW_JSON")
    if [ -f "$view_dir/github-server-head" ]; then
      match=
      prev=
      for arg in "$@"; do
        if [ "$prev" = "--match-head-commit" ]; then
          match=$arg
        fi
        prev=$arg
      done
      if [ -n "$match" ] && [ "$match" != "$(cat "$view_dir/github-server-head")" ]; then
        printf 'error: head out of date\n' >&2
        exit 1
      fi
    fi
    if [ -n "${FM_TEST_GH_MERGE_OUTPUT:-}" ]; then
      printf '%s\n' "$FM_TEST_GH_MERGE_OUTPUT"
    else
      printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}"
    fi
    merge_rc=0
    if [ -f "${FM_TEST_GH_MERGE_RC_FILE:-}" ]; then
      merge_rc=$(cat "$FM_TEST_GH_MERGE_RC_FILE")
    fi
    exit "$merge_rc"
    ;;
  "api graphql")
    if [ -f "${FM_TEST_GH_GRAPHQL_FAIL:-}" ]; then
      echo 'error: could not reach the GitHub API' >&2
      exit 1
    fi
    cat "$FM_TEST_GH_OUTCOME"
    exit 0
    ;;
  api\ *)
    # The required-check reads: the branch itself, and its rules read without
    # the merge-queue filter the queue reader below applies.
    case " $* " in
      *" repos/"*"/pulls/"*"/commits "*)
        if [ -f "$FM_TEST_GH_PR_COMMITS" ]; then
          cat "$FM_TEST_GH_PR_COMMITS"
        else
          jq -n --arg head "$(cat "$FM_TEST_GH_HEAD")" \
            --arg merge "$(cat "$FM_TEST_GH_PR_MERGE_COMMITS" 2>/dev/null)" \
            '[{sha: $head, parents: (if $merge == "" then [{sha: "parent"}] else [{sha: "parent"}, {sha: "upstream"}] end)}]'
        fi
        exit 0
        ;;
      *" repos/example/repo --jq .allow_merge_commit "*)
        cat "$FM_TEST_GH_ALLOW_MERGE_COMMIT" 2>/dev/null || echo true
        exit 0
        ;;
      *" repos/"*"/pulls/"*"/update-branch "*)
        [ "${2:-}" = --method ] && [ "${3:-}" = PUT ] || exit 2
        expected=
        for arg in "$@"; do
          case "$arg" in expected_head_sha=*) expected=${arg#expected_head_sha=} ;; esac
        done
        [ -n "$expected" ] || exit 2
        server_head="$(dirname "$FM_TEST_GH_VIEW_JSON")/github-server-head"
        current=$(cat "$server_head" 2>/dev/null || cat "$FM_TEST_GH_HEAD")
        if [ "$current" != "$expected" ]; then
          printf 'gh: Head branch was modified. Review and try again. (HTTP 422)\n' >&2
          exit 1
        fi
        cp "$FM_TEST_GH_UPDATE_HEAD" "$FM_TEST_GH_HEAD"
        cp "$FM_TEST_GH_UPDATE_HEAD" "$server_head"
        : > "$FM_TEST_GH_UPDATE_DONE"
        printf '{"message":"Updating pull request branch."}\n'
        exit 0
        ;;
      *" repos/"*"/commits/"*"/check-runs"*)
        case "$*" in
          *"/commits/$(cat "$FM_TEST_GH_HEAD")/check-runs"*) ;;
          *) exit 1 ;;
        esac
        cat "$FM_TEST_GH_RUNS"
        exit $?
        ;;
      *" repos/"*"/rules/branches/"*merge_queue*) ;;
      *" repos/"*"/rules/branches/"*)
        if [ -f "${FM_TEST_GH_REQUIRED_RULES_FAIL:-}" ]; then
          cat "$FM_TEST_GH_REQUIRED_RULES_FAIL" >&2
          exit 1
        fi
        cat "$FM_TEST_GH_REQUIRED_RULES"
        exit 0
        ;;
      *" repos/"*"/branches/"*)
        if [ -f "$FM_TEST_GH_BRANCH_FAIL-after-update" ] && [ -f "$FM_TEST_GH_UPDATE_DONE" ]; then
          cat "$FM_TEST_GH_BRANCH_FAIL-after-update" >&2
          exit 1
        fi
        if [ -f "${FM_TEST_GH_BRANCH_FAIL:-}" ]; then
          cat "$FM_TEST_GH_BRANCH_FAIL" >&2
          exit 1
        fi
        cat "$FM_TEST_GH_BRANCH"
        exit 0
        ;;
    esac
    if [ -f "${FM_TEST_GH_RULES_FAIL_BODY:-}" ]; then
      cat "$FM_TEST_GH_RULES_FAIL_BODY" >&2
      exit 1
    fi
    if [ -f "${FM_TEST_GH_RULES_FAIL:-}" ]; then
      exit 1
    fi
    cat "$FM_TEST_GH_RULES"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh mock that fails the merge call but succeeds live verify, so a real merge
# failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  local head=${2:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}
  add_gh_mocks "$case_dir" "$head"
  printf '1\n' > "$case_dir/github-merge-rc"
  printf 'error: pr merge failed\n' > "$case_dir/github-merge-output"
}

# Flag the shared gh mock so GraphQL outcome reads fail while live verify and
# merge still succeed. Args: case_dir [head_sha ignored]
add_gh_mock_outcome_read_fails() {
  local case_dir=$1
  : > "$case_dir/github-graphql-fail"
}

# gh-axi mock that merges but cannot answer its own view, so a case can prove
# what happens when neither reader can establish the outcome. Args: case_dir
add_gh_axi_mock_view_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}" ;;
  "pr view") exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
}

add_failing_poll_publish_mv() {
  local case_dir=$1
  cat > "$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */.fm-pr-poll-data.*) exit 1 ;;
  esac
done
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$case_dir/fakebin/mv"
}

# glab mock recording every invocation together with the GITLAB_HOST it was
# given, so a test can prove the instance came from the URL. `mr view` answers
# from the case's JSON payload; marker files in the case dir drive the failure
# modes, so no test has to leak environment into a shared runner.
add_glab_mock() {
  local case_dir=$1
  cat > "$case_dir/fakebin/glab" <<'SH'
#!/usr/bin/env bash
printf 'GITLAB_HOST=%s %s\n' "${GITLAB_HOST-<unset>}" "$*" >> "$FM_TEST_GLAB_LOG"
case_dir=$(dirname "$FM_TEST_GLAB_JSON")
case "${1:-} ${2:-}" in
  "mr view")
    [ ! -e "$case_dir/glab-view-fails" ] || exit 1
    if [ -e "$case_dir/glab-merge-called" ] && [ ! -e "$case_dir/glab-stays-open" ]; then
      cat "$case_dir/mr-post.json"
    else
      cat "$FM_TEST_GLAB_JSON"
      if [ -f "$case_dir/glab-head-after-view" ]; then
        cp "$case_dir/glab-head-after-view" "$case_dir/glab-server-head"
        rm -f "$case_dir/glab-head-after-view"
      fi
    fi
    exit 0
    ;;
  "mr merge")
    if [ -f "$case_dir/glab-server-head" ]; then
      sha=
      prev=
      for arg in "$@"; do
        if [ "$prev" = "--sha" ]; then
          sha=$arg
        fi
        prev=$arg
      done
      if [ -n "$sha" ] && [ "$sha" != "$(cat "$case_dir/glab-server-head")" ]; then
        echo "error: head out of date" >&2
        exit 1
      fi
    fi
    [ ! -e "$case_dir/glab-merge-fails" ] || { echo "error: mr merge failed" >&2 ; exit 1 ; }
    : > "$case_dir/glab-merge-called"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/glab"
  ln -sf "$JQ_BIN" "$case_dir/fakebin/jq"
}

# write_mr_json <file> [<field>=<value> ...]
# A merge request payload that satisfies every pre-merge condition, with the
# named fields overridden so one case drives exactly one condition. Values are
# written into the JSON as-is, so a value may carry a JSON escape.
write_mr_json() {
  local file=$1 kv key value
  local state=opened detail=mergeable conflicts=false discussions=true
  local head=$MR_HEAD pipeline_sha=$MR_HEAD pipeline_status=success pipeline=present
  local merge_when_pipeline_succeeds=false merge_after=null
  shift
  for kv in "$@"; do
    key=${kv%%=*}
    value=${kv#*=}
    case "$key" in
      state) state=$value ;;
      detail) detail=$value ;;
      conflicts) conflicts=$value ;;
      discussions) discussions=$value ;;
      head) head=$value ;;
      pipeline_sha) pipeline_sha=$value ;;
      pipeline_status) pipeline_status=$value ;;
      pipeline) pipeline=$value ;;
      merge_when_pipeline_succeeds) merge_when_pipeline_succeeds=$value ;;
      merge_after) merge_after=$value ;;
      *) fail "write_mr_json: unknown field '$key'" ;;
    esac
  done
  if [ "$pipeline" = present ]; then
    pipeline=$(printf '{"sha":"%s","status":"%s"}' "$pipeline_sha" "$pipeline_status")
  fi
  printf '{"iid":7,"state":"%s","detailed_merge_status":"%s","has_conflicts":%s,' \
    "$state" "$detail" "$conflicts" > "$file"
  printf '"blocking_discussions_resolved":%s,"sha":"%s","head_pipeline":%s,' \
    "$discussions" "$head" "$pipeline" >> "$file"
  printf '"merge_when_pipeline_succeeds":%s,"merge_after":%s}\n' \
    "$merge_when_pipeline_succeeds" "$merge_after" >> "$file"
}

# tea mock recording every invocation, so a test can prove the login and
# --repo slug used. "login list" answers from a fixture logins file; a plain
# read of /repos/.../pulls/<n> answers from pr.json (or pr-post.json once a
# merge has been recorded, mirroring add_glab_mock's post-merge switch);
# /repos/.../commits/<sha>/status answers its first page from tea-status.json
# and page <n> from tea-status-page<n>.json, an empty page once that file is
# absent, so a case can put a failing context past the first page; a POST to
# .../pulls/<n>/merge is the one path that can actually record a merge. The
# repository read /repos/{owner}/{repo} answers from tea-repo.json, or a
# default_merge_style of merge when that file is absent.
# Verified against a real Forgejo instance that "tea api" reports an
# HTTP-level failure with exit status 0 and the error only in the body
# (docs/forgejo-tea-integration.md), so every branch here exits 0 too - a test
# that wants a merge refused writes tea-merge-fails and expects fm-pr-merge.sh
# to detect it only through the follow-up confirm read, never through this
# mock's own exit status.
add_tea_mock() {
  local case_dir=$1
  cat > "$case_dir/fakebin/tea" <<'SH'
#!/usr/bin/env bash
set -u
log_dir=$(dirname "$FM_TEST_TEA_LOG")
printf '%s\n' "$*" >> "$FM_TEST_TEA_LOG"

if [ "${1:-} ${2:-}" = "login list" ]; then
  cat "$log_dir/tea-logins.json"
  exit 0
fi

[ "${1:-}" = api ] || exit 0
shift
endpoint= do_value= head_commit_id=
while [ $# -gt 0 ]; do
  case "$1" in
    -X) shift 2 ;;
    --login|--repo) shift 2 ;;
    -f)
      case "$2" in
        Do=*) do_value=${2#Do=} ;;
        head_commit_id=*) head_commit_id=${2#head_commit_id=} ;;
      esac
      shift 2
      ;;
    /repos/*) endpoint=$1; shift ;;
    *) shift ;;
  esac
done
case "$endpoint" in
  */status|*/status\?*)
    [ ! -e "$log_dir/tea-status-fails" ] || exit 1
    page=1
    case "$endpoint" in
      *page=*) page=${endpoint##*page=}; page=${page%%&*} ;;
    esac
    if [ "$page" = 1 ]; then
      cat "$log_dir/tea-status.json"
    elif [ -e "$log_dir/tea-status-page$page.json" ]; then
      cat "$log_dir/tea-status-page$page.json"
    else
      printf '{"state":"","total_count":0,"statuses":[]}\n'
    fi
    ;;
  "/repos/{owner}/{repo}")
    [ ! -e "$log_dir/tea-repo-fails" ] || exit 1
    if [ -e "$log_dir/tea-repo.json" ]; then
      cat "$log_dir/tea-repo.json"
    else
      printf '{"default_merge_style":"merge"}\n'
    fi
    ;;
  */merge)
    if [ -e "$log_dir/tea-merge-fails" ]; then
      printf '{"message":"merge failed"}\n'
    elif [ -e "$log_dir/tea-expected-head" ] \
      && [ "$head_commit_id" != "$(cat "$log_dir/tea-expected-head")" ]; then
      printf '{"message":"head out of date"}\n'
    else
      : > "$log_dir/tea-merge-called"
      printf '%s\n' "$do_value" > "$log_dir/tea-merge-do"
      : > "$log_dir/tea-merged"
      printf '{}\n'
    fi
    ;;
  *)
    [ ! -e "$log_dir/tea-view-fails" ] || exit 1
    if [ -e "$log_dir/tea-merged" ] && [ -s "$log_dir/tea-post-merge-view-failures" ]; then
      left=$(cat "$log_dir/tea-post-merge-view-failures")
      if [ "$left" -gt 0 ]; then
        printf '%s\n' "$((left - 1))" > "$log_dir/tea-post-merge-view-failures"
        exit 1
      fi
    fi
    if [ -e "$log_dir/tea-merged" ]; then
      cat "$log_dir/pr-post.json"
    else
      cat "$log_dir/pr.json"
      if [ -f "$log_dir/tea-head-after-view" ]; then
        cp "$log_dir/tea-head-after-view" "$log_dir/tea-expected-head"
        rm -f "$log_dir/tea-head-after-view"
      fi
    fi
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tea"
  ln -sf "$JQ_BIN" "$case_dir/fakebin/jq"
}

# write_forgejo_pr_json <file> [<field>=<value> ...]
# A pull request payload that satisfies every pre-merge condition by default,
# with named fields overridden so one case drives exactly one condition.
write_forgejo_pr_json() {
  local file=$1 kv key value
  local state=open mergeable=true merged=false draft=false head=$FJ_HEAD
  shift
  for kv in "$@"; do
    key=${kv%%=*}
    value=${kv#*=}
    case "$key" in
      state) state=$value ;;
      mergeable) mergeable=$value ;;
      merged) merged=$value ;;
      draft) draft=$value ;;
      head) head=$value ;;
      *) fail "write_forgejo_pr_json: unknown field '$key'" ;;
    esac
  done
  printf '{"state":"%s","mergeable":%s,"merged":%s,"draft":%s,"head":{"sha":"%s"}}\n' \
    "$state" "$mergeable" "$merged" "$draft" "$head" > "$file"
}

# write_forgejo_status_json <file> [state=<value>] [total_count=<n>]
# Defaults to a successful combined status; total_count=0 renders the
# unconfigured-CI shape verified against a real instance (empty state, zero
# count), regardless of any state= override.
write_forgejo_status_json() {
  local file=$1 kv key value
  local state=success total=1
  shift
  for kv in "$@"; do
    key=${kv%%=*}
    value=${kv#*=}
    case "$key" in
      state) state=$value ;;
      total_count) total=$value ;;
      *) fail "write_forgejo_status_json: unknown field '$key'" ;;
    esac
  done
  if [ "$total" = 0 ]; then
    printf '{"state":"","total_count":0,"statuses":[]}\n' > "$file"
  else
    jq -n --arg state "$state" --argjson total "$total" \
      '{state: $state, total_count: $total,
        statuses: [range(1; $total + 1) | {context: ("ci-" + tostring), status: $state}]}' \
      > "$file"
  fi
}

# write_tea_logins_json <file> <name> <url> [<name> <url> ...]
# Reproduces the multi-line pretty-printed shape of a real
# `tea login list --output json` (docs/forgejo-tea-integration.md). The login
# match parses it as JSON, so tests/fm-pr-check-security.test.sh pins the
# compact single-line shapes separately.
write_tea_logins_json() {
  local file=$1 name url first=1
  shift
  : > "$file"
  printf '[\n' >> "$file"
  while [ "$#" -gt 0 ]; do
    name=$1
    url=$2
    shift 2
    [ "$first" = 1 ] || printf ',\n' >> "$file"
    first=0
    printf '  {\n    "name": "%s",\n    "url": "%s",\n    "ssh_host": "",\n    "user": "",\n    "default": "false"\n  }' \
      "$name" "$url" >> "$file"
  done
  printf '\n]\n' >> "$file"
}

# make_forgejo_case <name> [<pr-field>=<value> ...]: a case dir with the tea
# mock, a matching login fixture, a pull request payload, and a successful
# combined status. Echoes the case dir.
make_forgejo_case() {
  local name=$1 case_dir
  shift
  case_dir=$(make_case "$name")
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  add_tea_mock "$case_dir"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/tea.log"
  write_tea_logins_json "$case_dir/tea-logins.json" "$FJ_LOGIN" "https://$FJ_HOST"
  write_forgejo_pr_json "$case_dir/pr.json" "$@"
  write_forgejo_pr_json "$case_dir/pr-post.json" state=closed mergeable=false merged=true head="$FJ_HEAD"
  write_forgejo_status_json "$case_dir/tea-status.json"
  printf '%s\n' "$FJ_HEAD" > "$case_dir/tea-expected-head"
  printf '%s\n' "$case_dir"
}

# make_gitlab_case <name> [<field>=<value> ...]: a case dir with both forge
# mocks and a merge request payload. Echoes the case dir.
make_gitlab_case() {
  local name=$1 case_dir
  shift
  case_dir=$(make_case "$name")
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  add_glab_mock "$case_dir"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/glab.log"
  write_mr_json "$case_dir/mr.json" "$@"
  write_mr_json "$case_dir/mr-post.json" state=merged
  printf '%s\n' "$case_dir"
}

# mirror_path_without <dir> <tool> [<bindir> ...]: the whole search path
# re-exposed by symlink except one tool, because a real copy anywhere on PATH
# would prove nothing. The named bindirs are mirrored ahead of the search path,
# so the case's own mocks answer for every tool that is not the omitted one and
# the refusal names that tool alone whatever the host happens to have installed.
mirror_path_without() {
  local dir=$1 omit=$2 search bindir entry name
  shift 2
  mkdir -p "$dir"
  search=$(printf '%s\n' "$@"; printf '%s\n' "$BASE_PATH" | tr ':' '\n')
  while IFS= read -r bindir; do
    [ -d "$bindir" ] || continue
    for entry in "$bindir"/*; do
      [ -e "$entry" ] || continue
      name=${entry##*/}
      [ "$name" = "$omit" ] && continue
      [ -e "$dir/$name" ] || ln -s "$entry" "$dir/$name" 2>/dev/null
    done
  done <<EOF
$search
EOF
  # Bash 3.2 answers command -v from its hash table even under a temporary PATH.
  hash -r
  ! PATH="$dir" command -v "$omit" >/dev/null 2>&1 \
    || fail "the $omit-free search path still resolved $omit"
}

# The merge line glab was asked to run, so a test asserts one exact invocation
# rather than a substring of the whole log.
glab_merge_line() {
  grep -F ' mr merge ' "$1" || true
}

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="${FM_TEST_HOME:-$case_dir/home}" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_GH_OUTCOME="$case_dir/github-outcome" \
  FM_TEST_GH_RULES="$case_dir/github-rules" \
  FM_TEST_GH_VIEW_JSON="$case_dir/github-view.json" \
  FM_TEST_GH_MERGEABLE_SEQUENCE="${FM_TEST_GH_MERGEABLE_SEQUENCE:-}" \
  FM_TEST_GH_MERGEABLE_CALLS="$case_dir/mergeable-calls" \
  FM_TEST_GH_UPDATE_VIEW="$case_dir/github-view-after-update.json" \
  FM_TEST_GH_UPDATE_FINAL_VIEW="$case_dir/github-view-after-update-final.json" \
  FM_TEST_GH_UPDATE_DONE="$case_dir/github-update-done" \
  FM_TEST_GH_UPDATE_HEAD="$case_dir/github-head-after-update" \
  FM_TEST_GH_HEAD="$case_dir/github-head" \
  FM_TEST_GH_PR_COMMITS="$case_dir/github-pr-commits.json" \
  FM_TEST_GH_PR_MERGE_COMMITS="$case_dir/github-pr-merge-commits" \
  FM_TEST_GH_ALLOW_MERGE_COMMIT="$case_dir/github-allow-merge-commit" \
  FM_TEST_GH_TEXT_JSON="$case_dir/github-text.json" \
  FM_TEST_GH_MERGE_ARGS="$case_dir/github-merge-args" \
  FM_TEST_GH_RUNS="$case_dir/github-runs.json" \
  FM_TEST_GH_MERGE_RC_FILE="$case_dir/github-merge-rc" \
  FM_TEST_GH_MERGE_OUTPUT="$(cat "$case_dir/github-merge-output" 2>/dev/null || true)" \
  FM_TEST_GH_GRAPHQL_FAIL="$case_dir/github-graphql-fail" \
  FM_TEST_GH_RULES_FAIL="$case_dir/github-rules-fail" \
  FM_TEST_GH_RULES_FAIL_BODY="$case_dir/github-rules-fail-body" \
  FM_TEST_GH_BRANCH="$case_dir/github-branch.json" \
  FM_TEST_GH_BRANCH_FAIL="$case_dir/github-branch-fail" \
  FM_TEST_GH_REQUIRED_RULES="$case_dir/github-required-rules.json" \
  FM_TEST_GH_REQUIRED_RULES_FAIL="$case_dir/github-required-rules-fail" \
  FM_TEST_META_AT_MERGE="$case_dir/meta-at-merge" \
  FM_TEST_AWAY_RECORD_AFTER_VIEW="$case_dir/away-record-after-view" \
  FM_TEST_ROOT="$ROOT" \
  FM_TEST_AWAY_MUTATE_AT_MERGE="${FM_TEST_AWAY_MUTATE_AT_MERGE:-}" \
  FM_TEST_AWAY_MUTATE_OUT="$case_dir/away-mutate-output" \
  FM_TEST_AWAY_MUTATE_RC="$case_dir/away-mutate-rc" \
  FM_TEST_AWAY_WORDS_AT_MERGE="$case_dir/away-words-at-merge" \
  FM_TEST_REAL_MV="$REAL_MV" \
  FM_TEST_GLAB_LOG="$case_dir/glab.log" \
  FM_TEST_GLAB_JSON="$case_dir/mr.json" \
  FM_TEST_TEA_LOG="$case_dir/tea.log" \
  HOME="${FM_TEST_USER_HOME:-$case_dir/user-home}" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

write_github_outcome() {
  local case_dir=$1 state=$2 merged=$3 queued=$4 base=$5
  printf '%s\n' \
    "state=$state" \
    "merged=$merged" \
    "queued=$queued" \
    "base=$base" > "$case_dir/github-outcome"
}

write_away_record() {
  local case_dir=$1
  shift
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-afk-contract.sh" enter "$@" >/dev/null
}

test_verified_merge_records_pr_and_head() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  assert_logged_gh_merge "$case_dir" 9 example/repo --squash
  pass "fm-pr-merge records pr= and pr_head= for a verified GitHub merge"
}

# The forge call is the point of no return: once gh-axi has merged, nothing this
# script does afterwards can un-merge it. Proving pr= is already in the task's
# meta at that moment is what makes a later failure unable to lose the merge.
test_pr_metadata_is_recorded_before_the_forge_call() {
  local case_dir rc
  case_dir=$(make_case records-ahead-of-forge-call)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5151515151515151515151515151515151515151
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/meta-at-merge"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/62 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-ahead-of-forge-call: fm-pr-merge should succeed"
  assert_logged_gh_merge "$case_dir" 62 example/repo --squash
  assert_grep 'pr=https://github.com/example/repo/pull/62' "$case_dir/meta-at-merge" \
    "records-ahead-of-forge-call: the merge ran before pr= was recorded"
  pass "fm-pr-merge records pr= before the forge call can land the merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_github_merged_outcome_is_verified() {
  local case_dir rc
  case_dir=$(make_case github-verified-merged)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1010101010101010101010101010101010101010
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/51 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "github-verified-merged: a merged PR should succeed"
  assert_grep 'verified: https://github.com/example/repo/pull/51 is merged' \
    "$case_dir/stdout" "github-verified-merged: success was not reported as verified"
  assert_grep 'api graphql' "$case_dir/gh.log" \
    "github-verified-merged: the PR outcome was not read back after merging"
  pass "fm-pr-merge verifies a genuinely merged GitHub pull request"
}

test_github_verified_merge_requires_poll_recording() {
  local case_dir rc
  case_dir=$(make_case github-poll-recording-fails)
  add_gh_mocks "$case_dir" 1111111111111111111111111111111111111111
  add_failing_poll_publish_mv "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/55 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-poll-recording-fails: poll setup failure should fail the merge wrapper"
  assert_grep 'error: could not publish PR poll' "$case_dir/stderr" \
    "github-poll-recording-fails: poll setup failure was not reported"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-poll-recording-fails: failed poll setup was reported as a verified merge"
  assert_grep 'pr=https://github.com/example/repo/pull/55' "$case_dir/state/task-x1.meta" \
    "github-poll-recording-fails: metadata was not retained for the attempted merge"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "github-poll-recording-fails: the failed poll setup left a runnable poll"
  pass "fm-pr-merge refuses to claim a merge when poll recording fails"
}

test_github_open_unqueued_outcome_refuses() {
  local case_dir rc
  case_dir=$(make_case github-open-unqueued)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2020202020202020202020202020202020202020
  write_github_outcome "$case_dir" OPEN false false master
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/52 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-open-unqueued: an unproved merge must fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-open-unqueued: refusal did not name the concrete observed state"
  assert_grep 'pr=https://github.com/example/repo/pull/52' "$case_dir/state/task-x1.meta" \
    "github-open-unqueued: the attempted merge lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-open-unqueued: the attempted merge did not leave its poll armed"
  pass "fm-pr-merge refuses a GitHub merge call that leaves the PR open and unqueued"
}

# GitHub reports mergeable=UNKNOWN for a short while after a push or a base
# branch change while it recomputes mergeability. When that is the only
# failing condition, the gate re-reads and re-checks every live condition on
# a bounded retry instead of refusing a pull request that is simply pending.
test_github_mergeable_unknown_retries_then_succeeds() {
  local case_dir rc head
  head=4242424242424242424242424242424242424242
  case_dir=$(make_case github-mergeable-unknown-then-mergeable)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  printf '%s\n' UNKNOWN MERGEABLE > "$case_dir/mergeable-sequence"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  FM_TEST_GH_MERGEABLE_SEQUENCE="$case_dir/mergeable-sequence" \
  FM_PR_GITHUB_MERGEABLE_RETRY_DELAY=0 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/83 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "github-mergeable-unknown-then-mergeable: a merge should succeed once mergeable resolves"
  [ "$(grep -c '^pr view .*statusCheckRollup' "$case_dir/gh.log")" -eq 2 ] \
    || fail "github-mergeable-unknown-then-mergeable: expected exactly 2 mergeable reads, got $(grep -c '^pr view .*statusCheckRollup' "$case_dir/gh.log")"
  assert_logged_gh_merge "$case_dir" 83 example/repo --squash
  [ "$(grep -c '^pr merge ' "$case_dir/gh.log")" -eq 1 ] \
    || fail "github-mergeable-unknown-then-mergeable: the wrapper attempted more than one merge"
  assert_grep 'pr=https://github.com/example/repo/pull/83' "$case_dir/state/task-x1.meta" \
    "github-mergeable-unknown-then-mergeable: pr= was not recorded"
  pass "fm-pr-merge retries a bounded number of times when mergeable is UNKNOWN and merges once it resolves"
}

# Every attempt still reads mergeable=UNKNOWN: the bound is spent and the gate
# reports mergeability as still pending rather than calling the pull request
# unmergeable, never attempting a merge on an unresolved read.
test_github_mergeable_unknown_exhausts_bound_and_reports_pending() {
  local case_dir rc head
  head=4343434343434343434343434343434343434343
  case_dir=$(make_case github-mergeable-unknown-exhausted)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  printf '%s\n' UNKNOWN > "$case_dir/mergeable-sequence"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  FM_TEST_GH_MERGEABLE_SEQUENCE="$case_dir/mergeable-sequence" \
  FM_PR_GITHUB_MERGEABLE_RETRY_DELAY=0 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/84 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-mergeable-unknown-exhausted: a mergeable read that never resolves must still fail"
  [ "$(grep -c '^pr view .*statusCheckRollup' "$case_dir/gh.log")" -eq 5 ] \
    || fail "github-mergeable-unknown-exhausted: expected exactly 5 bounded mergeable reads, got $(grep -c '^pr view .*statusCheckRollup' "$case_dir/gh.log")"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-mergeable-unknown-exhausted: a merge was attempted while mergeable never resolved"
  assert_grep "mergeability for https://github.com/example/repo/pull/84 is still being computed by GitHub; retry shortly" \
    "$case_dir/stderr" \
    "github-mergeable-unknown-exhausted: the exhausted retry did not report mergeability as still pending"
  pass "fm-pr-merge reports mergeability still pending after its bounded UNKNOWN retry is spent"
}

# A check that turns red between two UNKNOWN reads must refuse on the re-check:
# the retry re-reads every live condition, not only mergeable.
test_github_mergeable_unknown_retry_rechecks_checks() {
  local case_dir rc head
  head=4545454545454545454545454545454545454545
  case_dir=$(make_case github-mergeable-unknown-check-turns-red)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  printf '%s\n' UNKNOWN 'UNKNOWN FAILURE' > "$case_dir/mergeable-sequence"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  FM_TEST_GH_MERGEABLE_SEQUENCE="$case_dir/mergeable-sequence" \
  FM_PR_GITHUB_MERGEABLE_RETRY_DELAY=0 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/86 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-mergeable-unknown-check-turns-red: a check that turned red must refuse"
  [ "$(grep -c '^pr view .*statusCheckRollup' "$case_dir/gh.log")" -eq 2 ] \
    || fail "github-mergeable-unknown-check-turns-red: expected exactly 2 reads, got $(grep -c '^pr view .*statusCheckRollup' "$case_dir/gh.log")"
  assert_grep "check 'ci' is not green" "$case_dir/stderr" \
    "github-mergeable-unknown-check-turns-red: the re-check did not refuse the red check"
  assert_no_grep 'still being computed' "$case_dir/stderr" \
    "github-mergeable-unknown-check-turns-red: a red check was reported as mergeability pending"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-mergeable-unknown-check-turns-red: gh pr merge ran after a check turned red"
  pass "fm-pr-merge refuses on the UNKNOWN re-check when a check turned red between reads"
}

# A real conflict (mergeable=CONFLICTING) is a different condition from GitHub
# still computing mergeability, and must refuse immediately like every other
# refusal, never retried.
test_github_mergeable_conflicting_is_not_retried() {
  local case_dir rc head
  head=4444444444444444444444444444444444444444
  case_dir=$(make_case github-mergeable-conflicting)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  jq -c '.mergeable = "CONFLICTING"' "$case_dir/github-view.json" > "$case_dir/github-view.tmp"
  mv "$case_dir/github-view.tmp" "$case_dir/github-view.json"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/85 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-mergeable-conflicting: a genuine conflict must refuse"
  [ "$(grep -c '^pr view .*statusCheckRollup' "$case_dir/gh.log")" -eq 1 ] \
    || fail "github-mergeable-conflicting: a genuine conflict was retried instead of refused immediately"
  assert_grep 'mergeable is "CONFLICTING", not MERGEABLE' "$case_dir/stderr" \
    "github-mergeable-conflicting: the conflict was not named"
  assert_no_grep 'still being computed' "$case_dir/stderr" \
    "github-mergeable-conflicting: a genuine conflict was reported as still being computed"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-mergeable-conflicting: gh pr merge ran on a conflicting PR"
  pass "fm-pr-merge refuses a genuine mergeable conflict immediately, without retrying"
}

test_github_unreadable_outcome_keeps_pr_bookkeeping() {
  local case_dir rc
  case_dir=$(make_case github-outcome-read-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 3131313131313131313131313131313131313131
  add_gh_mock_outcome_read_fails "$case_dir" 3131313131313131313131313131313131313131
  add_gh_axi_mock_view_fails "$case_dir"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/57 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-outcome-read-fails: an unreadable outcome must fail"
  assert_grep 'could not read the GitHub pull request outcome after the merge attempt' \
    "$case_dir/stderr" "github-outcome-read-fails: the unreadable outcome was not reported"
  assert_grep 'the gh read failed and the gh-axi view could not prove the outcome either' \
    "$case_dir/stderr" "github-outcome-read-fails: the refusal did not name both failed reads"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-outcome-read-fails: an unproved merge was reported as verified"
  # The merge call itself returned success, so the pull request may well have
  # landed. Losing the reference here would leave teardown with nothing to
  # verify against and no merge poll to catch up.
  assert_grep 'pr=https://github.com/example/repo/pull/57' "$case_dir/state/task-x1.meta" \
    "github-outcome-read-fails: a successful merge call lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-outcome-read-fails: no merge poll was armed for a merge that may have landed"
  pass "fm-pr-merge keeps PR bookkeeping when it cannot read a successful merge call's outcome"
}

test_github_refusal_quotes_the_forge_output() {
  local case_dir rc
  case_dir=$(make_case github-refusal-quotes-forge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6161616161616161616161616161616161616161
  printf '%s\n' 'will be added to the merge queue when all requirements are met' \
    > "$case_dir/github-merge-output"
  write_github_outcome "$case_dir" OPEN false false main
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/65 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-refusal-quotes-forge: an unproved merge must fail"
  assert_grep 'error: > will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    "github-refusal-quotes-forge: the forge's own explanation was discarded on the refusal"
  assert_grep "not this script's verdict" "$case_dir/stderr" \
    "github-refusal-quotes-forge: the forge's text was not marked as the forge's own"
  assert_grep 'error: GitHub merge outcome was not successful: state=OPEN, merged=false, isInMergeQueue=false' \
    "$case_dir/stderr" "github-refusal-quotes-forge: the wrapper's own verdict was lost"
  # A forge sentence about the merge queue must never stand on its own line, or
  # it reads as this script's verdict rather than as quoted forge output.
  ! grep -qxF 'will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    || fail "github-refusal-quotes-forge: forge text was emitted as the wrapper's own line"
  assert_no_grep 'will be added to the merge queue' "$case_dir/stdout" \
    "github-refusal-quotes-forge: the forge's unverified report leaked to stdout"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-refusal-quotes-forge: an unproved merge was reported as verified"
  pass "fm-pr-merge refuses with the forge's own output quoted apart from its verdict"
}

test_github_auto_merge_without_queue_refuses_legibly() {
  local case_dir rc spelling
  for spelling in --auto --auto=true; do
    case_dir=$(make_case "github-auto-no-queue${spelling#--auto}")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" 7171717171717171717171717171717171717171
    write_github_outcome "$case_dir" OPEN false false main
    : > "$case_dir/github-rules"
    : > "$case_dir/gh-axi.log"
    : > "$case_dir/gh.log"

    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/66 \
      --attended-override -- "$spelling" --merge \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "github-auto-no-queue: an armed but unlanded auto-merge must still fail"
    assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
      "github-auto-no-queue: refusal did not name the concrete observed state"
    assert_grep 'auto-merge was requested and armed for https://github.com/example/repo/pull/66' \
      "$case_dir/stderr" "github-auto-no-queue: the refusal never explained the armed auto-merge"
    assert_grep 'nothing is merged or in the merge queue yet' "$case_dir/stderr" \
      "github-auto-no-queue: the refusal left the operator to infer the pending state"
    assert_logged_gh_merge "$case_dir" 66 example/repo "$spelling" --merge
    [ "$(grep -c '^pr merge ' "$case_dir/gh.log")" -eq 1 ] \
      || fail "github-auto-no-queue: the wrapper attempted more than one merge"
    assert_grep 'pr=https://github.com/example/repo/pull/66' "$case_dir/state/task-x1.meta" \
      "github-auto-no-queue: the attempted merge lost its PR reference"
    assert_present "$case_dir/state/task-x1.check.sh" \
      "github-auto-no-queue: the attempted merge did not leave its poll armed"
  done
  pass "fm-pr-merge explains an armed auto-merge that landed nothing on a queue-less base"
}

test_github_failed_merge_never_claims_armed_auto_merge() {
  local case_dir rc
  case_dir=$(make_case github-auto-merge-command-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  write_github_outcome "$case_dir" OPEN false false main
  : > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/67 --attended-override -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-auto-merge-command-fails: the forge failure must still fail the wrapper"
  assert_grep 'error: pr merge failed' "$case_dir/stderr" \
    "github-auto-merge-command-fails: the original forge error was masked"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-auto-merge-command-fails: refusal did not name the concrete observed state"
  assert_no_grep 'armed' "$case_dir/stderr" \
    "github-auto-merge-command-fails: a failed merge command was reported as an armed auto-merge"
  assert_grep 'auto-merge was requested for https://github.com/example/repo/pull/67' \
    "$case_dir/stderr" \
    "github-auto-merge-command-fails: the refusal never said auto-merge had only been requested"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-auto-merge-command-fails: a failed merge command was reported as verified"
  pass "fm-pr-merge never reports auto-merge as armed when the merge command failed"
}

test_github_failed_merge_with_queue_flags_never_claims_acceptance() {
  local case_dir rc
  case_dir=$(make_case github-failed-merge-queue-flags)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/74 --attended-override -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-failed-merge-queue-flags: the forge failure must still fail the wrapper"
  assert_grep 'error: pr merge failed' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: the original forge error was masked"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: refusal did not name the concrete observed state"
  assert_no_grep 'was accepted with the exact flags' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: a failed merge command was reported as an accepted request"
  assert_no_grep 'armed' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: a failed merge command was reported as an armed auto-merge"
  assert_grep 'base branch main requires the merge queue; retry with:' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: the failed merge command lost its concrete retry guidance"
  assert_grep 'task-x1 https://github.com/example/repo/pull/74 --attended-override -- --auto --merge' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: the retry guidance named no queue flags"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-failed-merge-queue-flags: a failed merge command was reported as verified"
  pass "fm-pr-merge claims no acceptance for a failed merge command carrying queue flags"
}

test_github_accepted_queue_flags_do_not_echo_back_the_same_command() {
  local case_dir rc
  case_dir=$(make_case github-accepted-queue-flags)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8181818181818181818181818181818181818181
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/68 --attended-override -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-accepted-queue-flags: an unproved merge must still fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-accepted-queue-flags: refusal did not name the concrete observed state"
  assert_grep 'this run refuses even though the request for https://github.com/example/repo/pull/68 was accepted with the exact flags base branch main requires (--auto --merge)' \
    "$case_dir/stderr" \
    "github-accepted-queue-flags: the refusal did not explain that the right flags were already used"
  assert_grep "re-check the pull request's merge queue state" "$case_dir/stderr" \
    "github-accepted-queue-flags: the refusal named no concrete next step"
  assert_no_grep 'retry with:' "$case_dir/stderr" \
    "github-accepted-queue-flags: the refusal echoed back the command that just refused"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-accepted-queue-flags: an unproved merge was reported as verified"
  pass "fm-pr-merge does not echo back queue flags the caller already used"
}

test_github_mismatched_queue_flags_still_name_the_retry() {
  local case_dir rc
  case_dir=$(make_case github-mismatched-queue-flags)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8282828282828282828282828282828282828282
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=REBASE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/69 --attended-override -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-mismatched-queue-flags: an unproved merge must still fail"
  assert_grep 'base branch main requires the merge queue; retry with:' "$case_dir/stderr" \
    "github-mismatched-queue-flags: a caller method the queue does not use lost its retry guidance"
  assert_grep '--attended-override -- --auto --rebase' "$case_dir/stderr" \
    "github-mismatched-queue-flags: the exact compatible flags were not named"
  pass "fm-pr-merge still names retry flags when the caller used a different method"
}

test_github_unrecognised_queue_method_still_names_the_queue() {
  local case_dir rc
  case_dir=$(make_case github-unrecognised-queue-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8383838383838383838383838383838383838383
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=FASTFORWARD\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/70 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-unrecognised-queue-method: an unproved merge must fail"
  assert_grep 'base branch main requires the merge queue, but its configured merge method (FASTFORWARD) is not one this script recognises' \
    "$case_dir/stderr" \
    "github-unrecognised-queue-method: a readable queue rule produced no queue mention"
  assert_no_grep 'retry with:' "$case_dir/stderr" \
    "github-unrecognised-queue-method: retry flags were named for a method nothing recognises"
  assert_no_grep '--auto --' "$case_dir/stderr" \
    "github-unrecognised-queue-method: a merge method was guessed for the caller"
  pass "fm-pr-merge names the queue requirement even when its method is unrecognised"
}

test_github_unreadable_queue_rules_are_not_reported_as_no_queue() {
  local case_dir rc
  case_dir=$(make_case github-unreadable-queue-rules)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8484848484848484848484848484848484848484
  write_github_outcome "$case_dir" OPEN false false main
  : > "$case_dir/github-rules-fail"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/71 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-unreadable-queue-rules: an unproved merge must fail"
  assert_grep 'the branch rules for base branch main could not be read' "$case_dir/stderr" \
    "github-unreadable-queue-rules: an unreadable rules response read like a queue-less base"
  assert_no_grep 'retry with:' "$case_dir/stderr" \
    "github-unreadable-queue-rules: retry flags were named from rules nothing could read"
  pass "fm-pr-merge distinguishes unreadable branch rules from a base with no merge queue"
}

# A repository whose plan does not expose branch rules answers the rules
# endpoint with a 403 whose body is GitHub's own plan-upgrade message, not a
# generic auth or rate-limit failure. That repository cannot have a
# merge_queue rule either, so it must read as no queue rather than unreadable
# - an attended read still fails the merge here only because the queue-aware
# outcome read (api graphql) was never set up for this case, exactly like the
# no-queue-rule case below; the queue read itself is proven by the absence of
# 'merge-queue' wording in the refusal.
test_github_plan_gated_403_reads_as_no_queue() {
  local case_dir rc
  case_dir=$(make_case github-plan-gated-403)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8989898989898989898989898989898989898989
  write_github_outcome "$case_dir" OPEN false false main
  printf 'gh: Upgrade to GitHub Pro or make this repository public to enable this feature (HTTP 403)\n' \
    > "$case_dir/github-rules-fail-body"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/75 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-plan-gated-403: an unproved merge must fail"
  assert_no_grep 'merge queue' "$case_dir/stderr" \
    "github-plan-gated-403: a plan-gated 403 was read as an unreadable or present queue rule"
  assert_no_grep 'could not be read' "$case_dir/stderr" \
    "github-plan-gated-403: a plan-gated 403 was reported as an unreadable rules response"
  pass "fm-pr-merge reads a plan-gated 403 on branch rules as no merge queue, not unreadable"
}

# The practical effect of the fix: while away, a private repository's plan-gated 403
# must no longer refuse the merge the way any other unreadable queue response
# does.
test_away_plan_gated_403_does_not_block_the_merge() {
  local case_dir rc url head
  head=cececececececececececececececececececece
  url=https://github.com/example/repo/pull/91
  case_dir=$(make_case away-plan-gated-403)
  mkdir -p "$case_dir/wt" "$case_dir/home"
  add_gh_mocks "$case_dir" "$head"
  printf 'gh: Upgrade to GitHub Pro or make this repository public to enable this feature (HTTP 403)\n' \
    > "$case_dir/github-rules-fail-body"
  printf '\nyolo=on\n' >> "$case_dir/state/task-x1.meta"
  write_away_record "$case_dir"
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "away-plan-gated-403: a private repo's plan-gated 403 must not block an away merge"
  assert_logged_gh_merge "$case_dir" 91 example/repo --squash
  pass "away merge proceeds on a plan-gated 403 because that repository cannot have a merge queue"
}

test_github_no_queue_rule_says_nothing_about_a_queue() {
  local case_dir rc
  case_dir=$(make_case github-no-queue-rule)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8585858585858585858585858585858585858585
  write_github_outcome "$case_dir" OPEN false false main
  : > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/72 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-no-queue-rule: an unproved merge must fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-no-queue-rule: refusal did not name the concrete observed state"
  assert_no_grep 'merge queue' "$case_dir/stderr" \
    "github-no-queue-rule: a base with no queue rule was told it requires the merge queue"
  pass "fm-pr-merge says nothing about a merge queue when the base branch has no queue rule"
}

test_github_unmerged_fallback_cannot_replace_queue_aware_read() {
  local case_dir rc
  case_dir=$(make_case github-unmerged-fallback)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8686868686868686868686868686868686868686
  add_gh_mock_outcome_read_fails "$case_dir"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view") printf 'pull_request:\n  number: %s\n  state: open\n' "$3" ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/73 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-unmerged-fallback: an unproved merge must fail"
  assert_grep 'pr view 73 --repo example/repo' "$case_dir/gh-axi.log" \
    "github-unmerged-fallback: the fallback view was not consulted"
  assert_grep 'the gh read failed and the gh-axi view could not prove the outcome either' \
    "$case_dir/stderr" \
    "github-unmerged-fallback: an unmerged fallback was treated as a readable outcome"
  assert_no_grep 'GitHub merge outcome was not successful' "$case_dir/stderr" \
    "github-unmerged-fallback: an unmerged fallback reached detailed outcome handling"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-unmerged-fallback: an unproved merge was reported as verified"
  pass "fm-pr-merge accepts only a proved merge from the gh-axi fallback"
}

test_github_unreadable_outcome_refusal_quotes_the_forge_output() {
  local case_dir rc
  case_dir=$(make_case github-unreadable-outcome-quotes-forge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8787878787878787878787878787878787878787
  printf '%s\n' 'will be added to the merge queue when all requirements are met' \
    > "$case_dir/github-merge-output"
  add_gh_axi_mock_view_fails "$case_dir"
  add_gh_mock_outcome_read_fails "$case_dir" 8787878787878787878787878787878787878787
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/74 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-unreadable-outcome-quotes-forge: an unreadable outcome must fail"
  assert_grep 'could not read the GitHub pull request outcome after the merge attempt' \
    "$case_dir/stderr" \
    "github-unreadable-outcome-quotes-forge: the unreadable outcome was not reported"
  assert_grep 'error: > will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    "github-unreadable-outcome-quotes-forge: the forge's only evidence was discarded"
  ! grep -qxF 'will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    || fail "github-unreadable-outcome-quotes-forge: forge text was emitted as the wrapper's own line"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-unreadable-outcome-quotes-forge: an unproved merge was reported as verified"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-unreadable-outcome-quotes-forge: the attempted merge lost its merge poll"
  pass "fm-pr-merge quotes the forge output when it cannot read the outcome either"
}

test_github_failed_gh_read_falls_back_to_gh_axi() {
  local case_dir rc
  case_dir=$(make_case github-gh-read-falls-back)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5151515151515151515151515151515151515151
  add_gh_mock_outcome_read_fails "$case_dir" 5151515151515151515151515151515151515151
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/63 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "github-gh-read-falls-back: a merge the gh-axi view proves must succeed"
  assert_grep 'pr view 63 --repo example/repo' "$case_dir/gh-axi.log" \
    "github-gh-read-falls-back: the gh-axi view was never consulted after gh's read failed"
  assert_grep 'verified: https://github.com/example/repo/pull/63 is merged' \
    "$case_dir/stdout" "github-gh-read-falls-back: the proven merge was not reported"
  assert_grep 'pr=https://github.com/example/repo/pull/63' "$case_dir/state/task-x1.meta" \
    "github-gh-read-falls-back: the merged PR was not recorded for teardown"
  pass "fm-pr-merge falls back to the gh-axi view when gh's read fails"
}

test_github_failed_merge_names_an_observed_landed_state() {
  local case_dir rc
  case_dir=$(make_case github-failed-merge-actually-landed)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  write_github_outcome "$case_dir" MERGED true false main
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/64 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-failed-merge-actually-landed: the forge failure must still fail the wrapper"
  assert_grep 'error: pr merge failed' "$case_dir/stderr" \
    "github-failed-merge-actually-landed: the original forge error was masked"
  assert_grep 'state=MERGED, merged=true, isInMergeQueue=false' "$case_dir/stderr" \
    "github-failed-merge-actually-landed: the observed landed state was never named"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-failed-merge-actually-landed: a failed merge command was reported as verified"
  assert_grep 'pr=https://github.com/example/repo/pull/64' "$case_dir/state/task-x1.meta" \
    "github-failed-merge-actually-landed: the landed PR lost its reference"
  pass "fm-pr-merge names a landed state hiding behind a failed GitHub merge command"
}

test_github_without_gh_still_uses_gh_axi_merge() {
  local case_dir ghless_path rc
  case_dir=$(make_case github-without-gh)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4141414141414141414141414141414141414141
  rm "$case_dir/fakebin/gh"
  ghless_path="$case_dir/path-without-gh"
  mirror_path_without "$ghless_path" gh "$case_dir/fakebin"
  : > "$case_dir/gh-axi.log"

  set +e
  PATH="$ghless_path" run_pr_merge "$case_dir" task-x1 \
    https://github.com/example/repo/pull/60 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-without-gh: missing gh must refuse before recording"
  assert_grep 'merging a GitHub pull request requires gh on PATH' "$case_dir/stderr" \
    "github-without-gh: missing gh was not named"
  assert_no_grep 'pr=' "$case_dir/state/task-x1.meta" \
    "github-without-gh: pr= was recorded without gh"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "github-without-gh: a merge poll was armed without gh"
  pass "fm-pr-merge refuses a GitHub merge when gh is missing, before recording"
}

test_github_without_gh_failed_read_keeps_bookkeeping() {
  local case_dir ghless_path rc
  case_dir=$(make_case github-without-gh-read-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4141414141414141414141414141414141414141
  rm "$case_dir/fakebin/gh"
  ghless_path="$case_dir/path-without-gh"
  mirror_path_without "$ghless_path" gh "$case_dir/fakebin"
  : > "$case_dir/gh-axi.log"

  set +e
  PATH="$ghless_path" run_pr_merge "$case_dir" task-x1 \
    https://github.com/example/repo/pull/61 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-without-gh-read-fails: missing gh must refuse before recording"
  assert_grep 'merging a GitHub pull request requires gh on PATH' "$case_dir/stderr" \
    "github-without-gh-read-fails: missing gh was not named"
  assert_no_grep 'pr=' "$case_dir/state/task-x1.meta" \
    "github-without-gh-read-fails: pr= was recorded without gh"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "github-without-gh-read-fails: a merge poll was armed without gh"
  pass "fm-pr-merge refuses a GitHub merge when gh is missing rather than merging blind"
}

test_github_zero_exit_queue_required_refuses_with_exact_retry() {
  local case_dir rc
  case_dir=$(make_case github-zero-exit-queue-required)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2121212121212121212121212121212121212121
  write_github_outcome "$case_dir" OPEN false false 'release/2026'
  printf 'merge_method=REBASE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/56 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-zero-exit-queue-required: an unproved merge must fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-zero-exit-queue-required: refusal did not name the concrete observed state"
  assert_grep 'base branch release/2026 requires the merge queue' "$case_dir/stderr" \
    "github-zero-exit-queue-required: refusal did not name the queue requirement"
  assert_grep '--attended-override -- --auto --rebase' "$case_dir/stderr" \
    "github-zero-exit-queue-required: refusal did not name the exact compatible flags"
  assert_grep 'api --paginate repos/example/repo/rules/branches/release%2F2026' "$case_dir/gh.log" \
    "github-zero-exit-queue-required: queue rules were not read with pagination and encoded branch path"
  assert_logged_gh_merge "$case_dir" 56 example/repo --squash
  [ "$(grep -c '^pr merge ' "$case_dir/gh.log")" -eq 1 ] \
    || fail "github-zero-exit-queue-required: the wrapper attempted more than one merge"
  assert_no_grep --auto "$case_dir/gh.log" \
    "github-zero-exit-queue-required: queue flags were auto-applied to the attempted merge"
  assert_grep 'pr=https://github.com/example/repo/pull/56' "$case_dir/state/task-x1.meta" \
    "github-zero-exit-queue-required: the attempted merge lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-zero-exit-queue-required: the attempted merge did not leave its poll armed"
  pass "fm-pr-merge reports exact queue retry flags after a zero-exit false success"
}

test_github_closed_unqueued_outcome_omits_retry_flags() {
  local case_dir rc
  case_dir=$(make_case github-closed-unqueued)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2323232323232323232323232323232323232323
  write_github_outcome "$case_dir" CLOSED false false master
  printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/57 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-closed-unqueued: an unproved merge must fail"
  assert_grep 'state=CLOSED, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-closed-unqueued: refusal did not name the concrete observed state"
  assert_no_grep 'requires the merge queue' "$case_dir/stderr" \
    "github-closed-unqueued: closed PR received unusable queue guidance"
  assert_no_grep '--attended-override -- --auto --merge' "$case_dir/stderr" \
    "github-closed-unqueued: closed PR received retry flags"
  assert_grep 'pr=https://github.com/example/repo/pull/57' "$case_dir/state/task-x1.meta" \
    "github-closed-unqueued: the attempted merge lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-closed-unqueued: the attempted merge did not leave its poll armed"
  pass "fm-pr-merge omits merge-queue retry guidance for a closed GitHub PR"
}

test_github_queued_outcome_is_verified() {
  local case_dir rc
  case_dir=$(make_case github-verified-queued)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 3030303030303030303030303030303030303030
  write_github_outcome "$case_dir" OPEN false true master
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/53 --attended-override -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "github-verified-queued: a queued PR should succeed"
  assert_grep 'verified: https://github.com/example/repo/pull/53 is queued' \
    "$case_dir/stdout" "github-verified-queued: success was not reported as queued"
  assert_no_grep 'merged:' "$case_dir/stdout" \
    "github-verified-queued: the forge CLI's unverified merged report leaked through"
  assert_grep 'pr=https://github.com/example/repo/pull/53' "$case_dir/state/task-x1.meta" \
    "github-verified-queued: the queued PR was not recorded for teardown"
  pass "fm-pr-merge accepts and accurately reports a GitHub merge-queue entry"
}

test_github_queue_required_refusal_names_retry_flags() {
  local case_dir rc
  case_dir=$(make_case github-queue-required)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  write_github_outcome "$case_dir" OPEN false false master
  printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/54 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-queue-required: an incompatible direct merge must fail"
  assert_grep 'error: pr merge failed' "$case_dir/stderr" \
    "github-queue-required: the original forge failure was not preserved"
  assert_grep 'base branch master requires the merge queue' "$case_dir/stderr" \
    "github-queue-required: refusal did not name the queue requirement"
  grep -F -- '--attended-override -- --auto --merge' "$case_dir/stderr" >/dev/null \
    || fail "github-queue-required: refusal did not name the exact compatible flags"
  assert_logged_gh_merge "$case_dir" 54 example/repo --squash
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-queue-required: the failed forge call did not leave the merge poll armed"
  pass "fm-pr-merge explains how to retry with the required GitHub merge queue method"
}

test_github_agreeing_queue_rules_keep_retry_guidance() {
  local case_dir rc
  case_dir=$(make_case github-agreeing-queue-rules)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2424242424242424242424242424242424242424
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=REBASE\nmerge_method=REBASE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/58 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-agreeing-queue-rules: an unproved merge must fail"
  assert_grep 'base branch main requires the merge queue' "$case_dir/stderr" \
    "github-agreeing-queue-rules: refusal did not name the queue requirement"
  assert_grep '--attended-override -- --auto --rebase' "$case_dir/stderr" \
    "github-agreeing-queue-rules: agreeing rules omitted exact retry flags"
  assert_no_grep 'exact retry flags are ambiguous' "$case_dir/stderr" \
    "github-agreeing-queue-rules: agreeing rules were reported as ambiguous"
  pass "fm-pr-merge aggregates agreeing merge-queue rules"
}

test_github_conflicting_queue_rules_report_ambiguity() {
  local case_dir rc
  case_dir=$(make_case github-conflicting-queue-rules)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2525252525252525252525252525252525252525
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=MERGE\nmerge_method=SQUASH\nmerge_method=SQUASH\n' \
    > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/59 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-conflicting-queue-rules: an unproved merge must fail"
  assert_grep 'base branch main has conflicting merge queue methods (MERGE, SQUASH)' \
    "$case_dir/stderr" \
    "github-conflicting-queue-rules: conflicting methods were not named"
  assert_no_grep '--attended-override -- --auto --merge' "$case_dir/stderr" \
    "github-conflicting-queue-rules: an exact retry method was guessed"
  assert_no_grep '--attended-override -- --auto --squash' "$case_dir/stderr" \
    "github-conflicting-queue-rules: an exact retry method was guessed"
  assert_no_grep 'SQUASH, SQUASH' "$case_dir/stderr" \
    "github-conflicting-queue-rules: a repeated queue method was named twice"
  pass "fm-pr-merge reports ambiguity for conflicting merge-queue rules"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "extra-args: branch deletion must be refused without --attended-override"
  assert_grep 'pass --attended-override only for an explicit captain instruction' "$case_dir/stderr" \
    "extra-args: refusal did not name --attended-override"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "extra-args: gh pr merge ran despite the denylist"

  case_dir=$(make_case extra-args-attended)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 \
    --attended-override -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args-attended: attended override should merge"
  assert_logged_gh_merge "$case_dir" 15 example/repo --squash --delete-branch
  pass "fm-pr-merge refuses branch deletion unless --attended-override is passed"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh.log" ] || fail "missing-meta: gh pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  # A near-miss GitLab URL: one namespace segment where a project needs at
  # least two. A well-formed merge request URL is merged now, so the refusal
  # has to be proven on a URL that genuinely does not parse.
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a malformed merge request URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_help_prints_usage_and_exits_zero() {
  local case_dir rc flag
  case_dir=$(make_case help)
  for flag in --help -h; do
    set +e
    run_pr_merge "$case_dir" "$flag" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    expect_code 0 "$rc" "help: fm-pr-merge $flag must exit 0"
    assert_grep 'fm-pr-merge.sh <task-id> <pr-url>' "$case_dir/stdout" \
      "help: $flag must print the usage line from the header on stdout"
    assert_grep 'Merge method on GitHub defaults to --squash' "$case_dir/stdout" \
      "help: $flag must print the whole header, not a truncated range"
    assert_no_grep '^#' "$case_dir/stdout" \
      "help: $flag must strip the comment markers"
    [ ! -s "$case_dir/stderr" ] || fail "help: $flag wrote to stderr: $(cat "$case_dir/stderr")"
    [ ! -s "$case_dir/gh.log" ] || fail "help: $flag invoked gh"
  done
  pass "fm-pr-merge --help and -h print the header usage and exit 0"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

# A bundled short-option cluster carries -R without ever being exactly -R, and
# both CLIs expand it one character at a time, so the guard has to read the
# whole cluster. On GitLab that redirect names an instance, not only a
# repository, so it must refuse before anything is recorded or read.
test_bundled_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case bundled-repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" abababababababababababababababababababab
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/6 -- -dR wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "bundled-repo-override: fm-pr-merge should refuse a bundled repo override"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "bundled-repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/6' "$case_dir/state/task-x1.meta" \
    "bundled-repo-override: PR URL was recorded before rejecting the bundled repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "bundled-repo-override: a bundled repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "bundled-repo-override: gh-axi pr merge was invoked despite the bundled repo override"

  case_dir=$(make_gitlab_case bundled-repo-override-gitlab)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" -- -yR https://other.example/g/p \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "bundled-repo-override-gitlab: fm-pr-merge should refuse a bundled instance override"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "bundled-repo-override-gitlab: refusal did not explain the repo override"
  assert_no_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "bundled-repo-override-gitlab: the URL was recorded before rejecting the bundled override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "bundled-repo-override-gitlab: a bundled override armed a merge poll"
  [ ! -s "$case_dir/glab.log" ] \
    || fail "bundled-repo-override-gitlab: glab was invoked despite the bundled override"

  # Only a cluster carrying the repository flag is refused: every other short
  # cluster is still the caller's business and still reaches the forge.
  case_dir=$(make_case bundled-non-repo-cluster)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" bcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbc
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/8 -- -d \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "bundled-non-repo-cluster: -d is branch deletion and must be refused"
  assert_grep 'pass --attended-override only for an explicit captain instruction' "$case_dir/stderr" \
    "bundled-non-repo-cluster: refusal did not name --attended-override"

  case_dir=$(make_case bundled-delete-attended)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" bcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbc
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/8 --attended-override -- -d \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "bundled-delete-attended: attended override should merge"
  assert_logged_gh_merge "$case_dir" 8 example/repo --squash -d
  pass "fm-pr-merge refuses a bundled short-option repo override and refuses -d unless attended"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  assert_logged_gh_merge "$case_dir" 22 example/repo --merge
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

# A pull request that itself merges another history, such as an upstream sync,
# must not be squashed by default: the squash would drop that ancestry.
test_merge_commit_pr_defaults_to_merge() {
  local case_dir rc
  case_dir=$(make_case merge-commit-default)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8181818181818181818181818181818181818181
  printf '%s\n' cccccccccccccccccccccccccccccccccccccccc > "$case_dir/github-pr-merge-commits"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/24 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "merge-commit-default: fm-pr-merge failed"
  assert_logged_gh_merge "$case_dir" 24 example/repo --merge
  assert_grep 'contains merge commits, so it is merged with --merge' "$case_dir/stderr" \
    "merge-commit-default: the --merge choice was not reported"

  case_dir=$(make_case merge-commit-explicit-squash)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8181818181818181818181818181818181818181
  printf '%s\n' cccccccccccccccccccccccccccccccccccccccc > "$case_dir/github-pr-merge-commits"
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/24 -- --squash \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "merge-commit-explicit-squash: fm-pr-merge failed"
  assert_logged_gh_merge "$case_dir" 24 example/repo --squash

  case_dir=$(make_case merge-commit-disallowed)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8181818181818181818181818181818181818181
  printf '%s\n' cccccccccccccccccccccccccccccccccccccccc > "$case_dir/github-pr-merge-commits"
  printf 'false\n' > "$case_dir/github-allow-merge-commit"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/24 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "merge-commit-disallowed: fm-pr-merge should refuse"
  assert_grep 'does not allow merge commits' "$case_dir/stderr" \
    "merge-commit-disallowed: the refusal did not name the disallowed method"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "merge-commit-disallowed: gh pr merge ran despite the refusal"
  pass "fm-pr-merge defaults a pull request with merge commits to --merge, honours explicit --squash, and refuses when merge commits are disallowed"
}

test_merge_commit_default_requires_preserving_queue() {
  local case_dir scenario mode rc
  local extra=()
  for mode in ordinary auto; do
    extra=()
    [ "$mode" != auto ] || extra=(-- --auto)
    for scenario in none merge agreeing squash rebase conflicting unknown empty unreadable; do
      case_dir=$(make_case "ancestry-queue-$mode-$scenario")
      mkdir -p "$case_dir/wt"
      add_gh_mocks "$case_dir" "$MR_HEAD"
      printf '%s\n' "$MR_HEAD" > "$case_dir/github-pr-merge-commits"
      case "$scenario" in
        none) : > "$case_dir/github-rules" ;;
        merge) printf 'merge_method=MERGE\n' > "$case_dir/github-rules" ;;
        agreeing) printf 'merge_method=MERGE\nmerge_method=MERGE\n' > "$case_dir/github-rules" ;;
        squash) printf 'merge_method=SQUASH\n' > "$case_dir/github-rules" ;;
        rebase) printf 'merge_method=REBASE\n' > "$case_dir/github-rules" ;;
        conflicting) printf 'merge_method=MERGE\nmerge_method=SQUASH\n' > "$case_dir/github-rules" ;;
        unknown) printf 'merge_method=UNKNOWN\n' > "$case_dir/github-rules" ;;
        empty) printf 'merge_method=\n' > "$case_dir/github-rules" ;;
        unreadable) : > "$case_dir/github-rules-fail" ;;
      esac
      [ "$scenario" = none ] || write_github_outcome "$case_dir" OPEN false true main
      rc=0
      run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/24 \
        --attended-override "${extra[@]+"${extra[@]}"}" \
        > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      case "$scenario" in
        none|merge|agreeing)
          expect_code 0 "$rc" "ancestry-queue-$mode-$scenario: compatible method refused"
          if [ "$mode" = auto ]; then
            assert_logged_gh_merge "$case_dir" 24 example/repo --merge --auto
          else
            assert_logged_gh_merge "$case_dir" 24 example/repo --merge
          fi
          if [ "$scenario" != none ]; then
            assert_grep 'is queued' "$case_dir/stdout" "ancestry-queue-$mode-$scenario: queue outcome missing"
          fi
          ;;
        *)
          expect_code 1 "$rc" "ancestry-queue-$mode-$scenario: unsafe queue accepted"
          assert_no_grep 'pr merge' "$case_dir/gh.log" "ancestry-queue-$mode-$scenario: submitted to forge"
          assert_grep 'does not prove ancestry preservation' "$case_dir/stderr" "ancestry-queue-$mode-$scenario: missing refusal"
          assert_no_grep 'to keep their ancestry' "$case_dir/stderr" "ancestry-queue-$mode-$scenario: falsely claimed preservation"
          ;;
      esac
    done
  done
  pass "automatic ancestry preservation refuses incompatible or uncertain queues before ordinary and auto submissions"
}

test_default_method_requires_complete_verified_history() {
  local case_dir scenario rc
  for scenario in capped changed-head empty malformed paginated; do
    case_dir=$(make_case "history-$scenario")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" "$MR_HEAD"
    case "$scenario" in
      capped)
        jq -n --arg head "$MR_HEAD" '[range(250) | {sha: $head, parents: [{sha: "parent"}]}]' \
          > "$case_dir/github-pr-commits.json"
        ;;
      changed-head)
        jq -n --arg head "$MR_STALE_HEAD" '[{sha: $head, parents: [{sha: "parent"}, {sha: "upstream"}]}]' \
          > "$case_dir/github-pr-commits.json"
        ;;
      empty) printf '[]\n' > "$case_dir/github-pr-commits.json" ;;
      malformed) printf '[{"sha":"%s"}]\n' "$MR_HEAD" > "$case_dir/github-pr-commits.json" ;;
      paginated)
        jq -n --arg head "$MR_HEAD" \
          '[{sha: "merge", parents: [{sha: "parent"}, {sha: "upstream"}]}], [{sha: $head, parents: [{sha: "merge"}]}]' \
          > "$case_dir/github-pr-commits.json"
        ;;
    esac
    rc=0
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/24 \
      > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    if [ "$scenario" = paginated ]; then
      expect_code 0 "$rc" "history-$scenario: complete history should merge"
      assert_logged_gh_merge "$case_dir" 24 example/repo --merge
    else
      expect_code 1 "$rc" "history-$scenario: unsafe default should refuse"
      assert_no_grep 'pr merge' "$case_dir/gh.log" "history-$scenario: merge ran"
      assert_grep 'complete commit history at the verified head' "$case_dir/stderr" "history-$scenario: missing diagnostic"
    fi
  done
  case_dir=$(make_case history-push-before-verification)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$MR_HEAD"
  printf '%s\n' "$MR_STALE_HEAD" > "$case_dir/github-pr-commits.json.next-head"
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/24 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "history-push-before-verification: merge failed"
  assert_logged_gh_merge "$case_dir" 24 example/repo --merge
  assert_grep "--match-head-commit $MR_STALE_HEAD" "$case_dir/gh.log" "history-push-before-verification: wrong merged head"
  pass "default merging requires complete history matching the verified head across pages"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  assert_logged_gh_merge "$case_dir" 23 example/repo --method=merge
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  assert_logged_gh_merge "$case_dir" 126 my-org/my-repo --squash
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

test_gitlab_url_resolves_and_merges() {
  local case_dir rc merge_line
  case_dir=$(make_gitlab_case gitlab-merges)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-merges: a well-formed merge request URL should merge, not error"
  assert_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "gitlab-merges: pr= was not recorded before merging"
  assert_grep "GITLAB_HOST=$MR_HOST mr view 7 -R $MR_PROJECT_URL -F json" "$case_dir/glab.log" \
    "gitlab-merges: the pre-merge state was not read from the project URL"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  [ "$merge_line" = "GITLAB_HOST=$MR_HOST mr merge 7 -R $MR_PROJECT_URL --sha $MR_HEAD --yes" ] \
    || fail "gitlab-merges: unexpected merge invocation: '$merge_line'"
  assert_grep "successful pipeline at head $MR_HEAD" "$case_dir/stderr" \
    "gitlab-merges: the verified head was not reported"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "gitlab-merges: a merge request reached the GitHub CLI"
  pass "fm-pr-merge merges a GitLab merge request through glab instead of refusing it"
}

test_gitlab_host_comes_from_the_url() {
  local case_dir rc host path project_url url
  host=gl.self-hosted.example
  path=deep/nested/group/project
  project_url="https://$host/$path"
  url="$project_url/-/merge_requests/31"
  case_dir=$(make_gitlab_case gitlab-host-from-url)

  set +e
  run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-host-from-url: a self-hosted merge request should merge"
  assert_grep "GITLAB_HOST=$host mr view 31 -R $project_url -F json" "$case_dir/glab.log" \
    "gitlab-host-from-url: the read did not use the host from the URL"
  assert_grep "GITLAB_HOST=$host mr merge 31 -R $project_url" "$case_dir/glab.log" \
    "gitlab-host-from-url: the merge did not use the host from the URL"
  assert_no_grep 'gitlab.com' "$case_dir/glab.log" \
    "gitlab-host-from-url: a host was assumed instead of taken from the URL"
  assert_no_grep '<unset>' "$case_dir/glab.log" \
    "gitlab-host-from-url: glab was left to resolve the instance from its own default"
  pass "fm-pr-merge takes the GitLab instance from the URL rather than assuming one"
}

test_gitlab_imposes_no_merge_method() {
  local case_dir rc merge_line flag
  case_dir=$(make_gitlab_case gitlab-no-method)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-no-method: merge should succeed"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  for flag in --squash --rebase --merge --method; do
    case "$merge_line" in
      *"$flag"*) fail "gitlab-no-method: '$flag' was imposed on GitLab: '$merge_line'" ;;
    esac
  done
  pass "fm-pr-merge imposes no merge method on GitLab, leaving the project's own one"
}

test_gitlab_extra_args_forwarded() {
  local case_dir rc merge_line
  case_dir=$(make_gitlab_case gitlab-extra-args)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" -- --remove-source-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "gitlab-extra-args: source-branch deletion must be refused without --attended-override"
  assert_grep 'pass --attended-override only for an explicit captain instruction' "$case_dir/stderr" \
    "gitlab-extra-args: refusal did not name --attended-override"
  [ ! -s "$case_dir/glab.log" ] || fail "gitlab-extra-args: glab ran despite the denylist"

  case_dir=$(make_gitlab_case gitlab-extra-args-attended)
  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" --attended-override -- --remove-source-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "gitlab-extra-args-attended: attended override should merge"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  [ "$merge_line" = "GITLAB_HOST=$MR_HOST mr merge 7 -R $MR_PROJECT_URL --sha $MR_HEAD --yes --remove-source-branch" ] \
    || fail "gitlab-extra-args-attended: extra glab flags were not forwarded: '$merge_line'"
  pass "fm-pr-merge refuses GitLab source-branch deletion unless --attended-override is passed"
}

test_gitlab_merge_failure_propagates() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-merge-fails)
  : > "$case_dir/glab-merge-fails"

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-merge-fails: a failing glab merge should not report success"
  assert_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "gitlab-merge-fails: pr= should already be recorded even though the merge failed"
  pass "fm-pr-merge propagates a real glab merge failure without silently succeeding"
}

# Each pre-merge condition, driven one at a time, so no condition can be
# carried by another. The refusal names that condition, no merge is attempted,
# and pr= is still recorded and the poll still armed exactly as the GitHub path
# leaves them when live verification or the gh merge fails.
test_gitlab_each_condition_refuses_independently() {
  local case_dir rc name expected spec
  set -- \
    "state|state=closed|state is \"closed\", not open" \
    "detail|detail=need_rebase|detailed_merge_status is \"need_rebase\", not mergeable" \
    "conflicts|conflicts=true|has_conflicts is \"true\", not false" \
    "discussions|discussions=false|blocking_discussions_resolved is \"false\", not true" \
    "pipeline-status|pipeline_status=failed|the head pipeline status is \"failed\", not success" \
    "pipeline-sha|pipeline_sha=$MR_STALE_HEAD|the head pipeline ran at \"$MR_STALE_HEAD\", not at the current head $MR_HEAD" \
    "no-pipeline|pipeline=null|the head pipeline status is \"none\", not success"
  for spec in "$@"; do
    name=${spec%%|*}
    expected=${spec##*|}
    spec=${spec#*|}
    case_dir=$(make_gitlab_case "gitlab-refuse-$name" "${spec%%|*}")

    set +e
    run_pr_merge "$case_dir" task-x1 "$MR_URL" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "gitlab-refuse-$name: fm-pr-merge should refuse"
    assert_grep "error: refusing to merge $MR_URL" "$case_dir/stderr" \
      "gitlab-refuse-$name: refusal did not name the merge request"
    assert_grep "$expected" "$case_dir/stderr" \
      "gitlab-refuse-$name: refusal did not name the failing condition"
    [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
      || fail "gitlab-refuse-$name: a merge was attempted despite the refusal"
    assert_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
      "gitlab-refuse-$name: a refusal should still leave the recorded PR reference"
    assert_present "$case_dir/state/task-x1.check.sh" \
      "gitlab-refuse-$name: a refusal should still leave the merge poll armed"
  done
  pass "fm-pr-merge refuses on each GitLab pre-merge condition independently"
}

test_gitlab_reports_every_failing_condition() {
  local case_dir rc expected
  case_dir=$(make_gitlab_case gitlab-refuse-all \
    state=closed detail=conflict conflicts=true discussions=false \
    pipeline_status=failed "pipeline_sha=$MR_STALE_HEAD")

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-refuse-all: fm-pr-merge should refuse"
  for expected in \
    'state is "closed", not open' \
    'detailed_merge_status is "conflict", not mergeable' \
    'has_conflicts is "true", not false' \
    'blocking_discussions_resolved is "false", not true' \
    'the head pipeline status is "failed", not success' \
    "the head pipeline ran at \"$MR_STALE_HEAD\", not at the current head $MR_HEAD"
  do
    assert_grep "$expected" "$case_dir/stderr" \
      "gitlab-refuse-all: '$expected' was not reported"
  done
  pass "fm-pr-merge reports every failing GitLab condition, not only the first"
}

test_gitlab_stale_recorded_head_is_reported() {
  local case_dir rc merge_line
  case_dir=$(make_gitlab_case gitlab-stale-head)
  # The recorded head is what a rebase leaves behind. It is read before
  # fm-pr-check.sh rewrites the metadata, which drops a head it cannot resolve
  # for a GitLab task, so reading it afterwards would find nothing at all.
  printf 'pr_head=%s\n' "$MR_STALE_HEAD" >> "$case_dir/state/task-x1.meta"

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-stale-head: the live head satisfies every condition, so it should merge"
  assert_grep "recorded head $MR_STALE_HEAD disagrees with the live head $MR_HEAD" \
    "$case_dir/stderr" "gitlab-stale-head: the stale recorded head was trusted silently"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  case "$merge_line" in
    *"--sha $MR_HEAD"*) : ;;
    *) fail "gitlab-stale-head: the merge was not bound to the live head: '$merge_line'" ;;
  esac
  assert_no_grep "pr_head=$MR_STALE_HEAD" "$case_dir/state/task-x1.meta" \
    "gitlab-stale-head: the recording step no longer drops an unresolvable GitLab head"
  pass "fm-pr-merge reports a stale recorded head and verifies the live one"
}

test_gitlab_unreadable_state_refuses() {
  local case_dir rc name
  for name in view-fails not-an-object split-value; do
    case_dir=$(make_gitlab_case "gitlab-unreadable-$name")
    case "$name" in
      view-fails) : > "$case_dir/glab-view-fails" ;;
      not-an-object) printf '[]\n' > "$case_dir/mr.json" ;;
      # A value carrying a newline splits into a line no field name matches, so
      # it must refuse rather than be truncated into a value a check accepts.
      split-value) write_mr_json "$case_dir/mr.json" 'state=opened\nnot-a-field' ;;
    esac

    set +e
    run_pr_merge "$case_dir" task-x1 "$MR_URL" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "gitlab-unreadable-$name: fm-pr-merge should refuse"
    assert_grep 'could not read the GitLab merge request state before merging' \
      "$case_dir/stderr" "gitlab-unreadable-$name: refusal did not name the unreadable state"
    [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
      || fail "gitlab-unreadable-$name: a merge was attempted on an unreadable state"
  done
  pass "fm-pr-merge refuses an unreadable GitLab merge request state rather than merging blind"
}

test_gitlab_invalid_head_refuses() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-invalid-head head=not-a-sha)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-invalid-head: fm-pr-merge should refuse"
  assert_grep 'could not read the GitLab merge request head commit before merging' \
    "$case_dir/stderr" "gitlab-invalid-head: refusal did not name the unreadable head"
  [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
    || fail "gitlab-invalid-head: a merge was bound to a head that is not a commit"
  pass "fm-pr-merge refuses a GitLab head commit it cannot validate"
}

test_gitlab_missing_tool_refuses_before_recording() {
  local case_dir rc tool other
  for tool in glab jq; do
    if [ "$tool" = glab ]; then other=jq; else other=glab; fi
    case_dir=$(make_gitlab_case "gitlab-no-$tool")
    mirror_path_without "$case_dir/no$tool" "$tool" "$case_dir/fakebin"
    # One tool absent, the other still answered by this case's own mock, so the
    # refusal names exactly one tool on a host that ships neither.
    PATH="$case_dir/no$tool" command -v "$other" >/dev/null 2>&1 \
      || fail "gitlab-no-$tool: the $tool-free search path lost the $other mock as well"

    set +e
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
    FM_TEST_GLAB_LOG="$case_dir/glab.log" \
    FM_TEST_GLAB_JSON="$case_dir/mr.json" \
    PATH="$case_dir/no$tool" \
      "$PR_MERGE" task-x1 "$MR_URL" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "gitlab-no-$tool: fm-pr-merge should refuse"
    assert_grep "error: merging a GitLab merge request requires $tool on PATH" \
      "$case_dir/stderr" "gitlab-no-$tool: refusal did not name the missing tool"
    assert_no_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
      "gitlab-no-$tool: a PR reference was recorded despite the missing tool"
    assert_absent "$case_dir/state/task-x1.check.sh" \
      "gitlab-no-$tool: a merge poll was armed despite the missing tool"
  done
  pass "fm-pr-merge refuses before recording anything when glab or jq is absent"
}

# tea_merge_line <tea.log> [n]: the nth (default: last) merge invocation logged
# against a .../pulls/<n>/merge endpoint, or empty if none.
tea_merge_line() {
  grep -F '/merge' "$1" 2>/dev/null | tail -1
}

test_forgejo_url_resolves_and_merges() {
  local case_dir rc merge_line
  case_dir=$(make_forgejo_case forgejo-merges)

  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "forgejo-merges: a well-formed pull request URL should merge, not error"
  assert_grep "pr=$FJ_URL" "$case_dir/state/task-x1.meta" \
    "forgejo-merges: pr= was not recorded before merging"
  assert_grep "--login $FJ_LOGIN --repo $FJ_OWNER/$FJ_REPO /repos/{owner}/{repo}/pulls/9" "$case_dir/tea.log" \
    "forgejo-merges: the pre-merge state was not read through the resolved login and repo slug"
  merge_line=$(tea_merge_line "$case_dir/tea.log")
  case "$merge_line" in
    *"--login $FJ_LOGIN --repo $FJ_OWNER/$FJ_REPO -X POST /repos/{owner}/{repo}/pulls/9/merge -f Do=merge -f head_commit_id=$FJ_HEAD"*) : ;;
    *) fail "forgejo-merges: unexpected merge invocation: '$merge_line'" ;;
  esac
  assert_grep "successful combined status at head $FJ_HEAD" "$case_dir/stderr" \
    "forgejo-merges: the verified head was not reported"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "forgejo-merges: a pull request reached the GitHub CLI"
  pass "fm-pr-merge merges a Forgejo pull request through tea api instead of refusing it"
}

test_forgejo_login_resolves_from_the_host() {
  local case_dir rc host url
  host=git.self-hosted.example
  url="https://$host/$FJ_OWNER/$FJ_REPO/pulls/12"
  case_dir=$(make_forgejo_case forgejo-login-from-host)
  write_tea_logins_json "$case_dir/tea-logins.json" \
    other "https://unrelated.example" "$FJ_LOGIN" "https://$host:3000"

  set +e
  run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "forgejo-login-from-host: the matching login (port stripped) should be resolved and merge"
  assert_grep "--login $FJ_LOGIN --repo $FJ_OWNER/$FJ_REPO /repos/{owner}/{repo}/pulls/12" "$case_dir/tea.log" \
    "forgejo-login-from-host: the login was not resolved from the URL's host"
  assert_no_grep 'other' "$case_dir/tea.log" \
    "forgejo-login-from-host: an unrelated login name leaked into a tea invocation"
  pass "fm-pr-merge resolves the tea login by matching the PR's host against every registered login"
}

test_forgejo_refuses_when_login_is_ambiguous() {
  local case_dir rc name
  for name in none two; do
    case_dir=$(make_forgejo_case "forgejo-login-$name")
    case "$name" in
      none) write_tea_logins_json "$case_dir/tea-logins.json" unrelated "https://elsewhere.example" ;;
      two) write_tea_logins_json "$case_dir/tea-logins.json" a "https://$FJ_HOST" b "https://$FJ_HOST" ;;
    esac

    set +e
    run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "forgejo-login-$name: fm-pr-merge should refuse"
    assert_grep "requires exactly one 'tea login' registered for that host" "$case_dir/stderr" \
      "forgejo-login-$name: refusal did not name the login requirement"
    assert_no_grep "pr=$FJ_URL" "$case_dir/state/task-x1.meta" \
      "forgejo-login-$name: a PR reference was recorded despite the ambiguous login"
    [ -z "$(tea_merge_line "$case_dir/tea.log")" ] \
      || fail "forgejo-login-$name: a merge was attempted with an unresolved login"
  done
  pass "fm-pr-merge refuses when zero or more than one tea login matches the pull request's host"
}

test_forgejo_each_condition_refuses_independently() {
  local case_dir rc name expected spec
  set -- \
    "state|state=closed|state is \"closed\", not open" \
    "mergeable|mergeable=false|mergeable is \"false\", not true" \
    "draft|draft=true|the pull request is a draft"
  for spec in "$@"; do
    name=${spec%%|*}
    expected=${spec##*|}
    spec=${spec#*|}
    case_dir=$(make_forgejo_case "forgejo-refuse-$name" "${spec%%|*}")

    set +e
    run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "forgejo-refuse-$name: fm-pr-merge should refuse"
    assert_grep "error: refusing to merge $FJ_URL" "$case_dir/stderr" \
      "forgejo-refuse-$name: refusal did not name the pull request"
    assert_grep "$expected" "$case_dir/stderr" \
      "forgejo-refuse-$name: refusal did not name the failing condition"
    [ -z "$(tea_merge_line "$case_dir/tea.log")" ] \
      || fail "forgejo-refuse-$name: a merge was attempted despite the refusal"
    assert_grep "pr=$FJ_URL" "$case_dir/state/task-x1.meta" \
      "forgejo-refuse-$name: a refusal should still leave the recorded PR reference"
    assert_present "$case_dir/state/task-x1.check.sh" \
      "forgejo-refuse-$name: a refusal should still leave the merge poll armed"
  done
  pass "fm-pr-merge refuses on each Forgejo pre-merge condition independently"
}

test_forgejo_unconfigured_ci_refuses_as_none() {
  local case_dir rc
  case_dir=$(make_forgejo_case forgejo-ci-none)
  write_forgejo_status_json "$case_dir/tea-status.json" total_count=0

  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "forgejo-ci-none: an open, mergeable PR with no configured CI should still refuse"
  assert_grep 'the combined commit status is "none", not success' "$case_dir/stderr" \
    "forgejo-ci-none: an absent combined status was not reported as none"
  [ -z "$(tea_merge_line "$case_dir/tea.log")" ] \
    || fail "forgejo-ci-none: a merge was attempted with no configured CI"
  pass "fm-pr-merge treats an unconfigured Forgejo combined status as none, refusing rather than skipping the check"
}

# The combined status endpoint computes its state from one page of contexts,
# so a failing context on a later page must still refuse the merge, and a
# head whose every page is green must still merge.
test_forgejo_combined_status_reads_every_page() {
  local case_dir rc
  case_dir=$(make_forgejo_case forgejo-status-page2-red)
  write_forgejo_status_json "$case_dir/tea-status-page2.json" state=failure

  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "forgejo-status-page2-red: a failing context on page 2 should refuse"
  assert_grep 'the combined commit status is "failure", not success' "$case_dir/stderr" \
    "forgejo-status-page2-red: the later page's failure was not reported"
  [ -z "$(tea_merge_line "$case_dir/tea.log")" ] \
    || fail "forgejo-status-page2-red: a merge was attempted past a failing later page"

  case_dir=$(make_forgejo_case forgejo-status-page2-green)
  write_forgejo_status_json "$case_dir/tea-status-page2.json"

  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "forgejo-status-page2-green: every green page should merge"
  assert_grep 'page=2' "$case_dir/tea.log" \
    "forgejo-status-page2-green: the second status page was never read"
  pass "fm-pr-merge reads every Forgejo combined-status page before merging"
}

test_forgejo_stale_recorded_head_is_reported() {
  local case_dir rc merge_line
  case_dir=$(make_forgejo_case forgejo-stale-head)
  # The recorded head is what a rebase leaves behind. It is read before
  # fm-pr-check.sh rewrites the metadata, which drops a head it cannot resolve
  # for a Forgejo task, so reading it afterwards would find nothing at all.
  printf 'pr_head=%s\n' "$FJ_STALE_HEAD" >> "$case_dir/state/task-x1.meta"

  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "forgejo-stale-head: the live head satisfies every condition, so it should merge"
  assert_grep "recorded head $FJ_STALE_HEAD disagrees with the live head $FJ_HEAD" \
    "$case_dir/stderr" "forgejo-stale-head: the stale recorded head was trusted silently"
  merge_line=$(tea_merge_line "$case_dir/tea.log")
  case "$merge_line" in
    *"head_commit_id=$FJ_HEAD"*) : ;;
    *) fail "forgejo-stale-head: the merge was not bound to the live head: '$merge_line'" ;;
  esac
  assert_no_grep "pr_head=$FJ_STALE_HEAD" "$case_dir/state/task-x1.meta" \
    "forgejo-stale-head: the recording step no longer drops an unresolvable Forgejo head"
  pass "fm-pr-merge reports a stale recorded head and binds the merge to the live one instead"
}

test_forgejo_invalid_head_refuses() {
  local case_dir rc
  case_dir=$(make_forgejo_case forgejo-invalid-head head=not-a-sha)

  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "forgejo-invalid-head: fm-pr-merge should refuse"
  assert_grep 'could not read the Forgejo pull request head commit before merging' \
    "$case_dir/stderr" "forgejo-invalid-head: refusal did not name the unreadable head"
  [ -z "$(tea_merge_line "$case_dir/tea.log")" ] \
    || fail "forgejo-invalid-head: a merge was bound to a head that is not a commit"
  pass "fm-pr-merge refuses a Forgejo head commit it cannot validate"
}

test_forgejo_missing_tool_refuses_before_recording() {
  local case_dir rc tool other
  for tool in tea jq; do
    if [ "$tool" = tea ]; then other=jq; else other=tea; fi
    case_dir=$(make_forgejo_case "forgejo-no-$tool")
    mirror_path_without "$case_dir/no$tool" "$tool" "$case_dir/fakebin"
    PATH="$case_dir/no$tool" command -v "$other" >/dev/null 2>&1 \
      || fail "forgejo-no-$tool: the $tool-free search path lost the $other mock as well"

    set +e
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
    FM_TEST_TEA_LOG="$case_dir/tea.log" \
    PATH="$case_dir/no$tool" \
      "$PR_MERGE" task-x1 "$FJ_URL" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "forgejo-no-$tool: fm-pr-merge should refuse"
    assert_grep "error: merging a Forgejo pull request requires $tool on PATH" \
      "$case_dir/stderr" "forgejo-no-$tool: refusal did not name the missing tool"
    assert_no_grep "pr=$FJ_URL" "$case_dir/state/task-x1.meta" \
      "forgejo-no-$tool: a PR reference was recorded despite the missing tool"
    assert_absent "$case_dir/state/task-x1.check.sh" \
      "forgejo-no-$tool: a merge poll was armed despite the missing tool"
  done
  pass "fm-pr-merge refuses before recording anything when tea or jq is absent"
}

# The single most consequential finding in docs/forgejo-tea-integration.md:
# "tea api" reports an HTTP-level failure (a head-out-of-date rejection
# included) with exit status 0, verified against a real instance. A rejected
# merge here must therefore be caught only by the follow-up confirm read, not
# by trusting this mock's own (successful) exit status.
test_forgejo_rejected_merge_is_never_trusted_by_exit_status() {
  local case_dir rc
  case_dir=$(make_forgejo_case forgejo-rejected-merge)
  : > "$case_dir/tea-merge-fails"

  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "forgejo-rejected-merge: a rejected merge must fail even though tea api itself exits 0"
  assert_grep "Forgejo did not confirm $FJ_URL as merged" "$case_dir/stderr" \
    "forgejo-rejected-merge: refusal did not report the unconfirmed merge"
  assert_grep '"message":"merge failed"' "$case_dir/stderr" \
    "forgejo-rejected-merge: the forge's own rejection body was not quoted"
  [ ! -e "$case_dir/tea-merged" ] || fail "forgejo-rejected-merge: the mock recorded a landed merge"
  pass "fm-pr-merge never trusts tea api's exit status alone; a rejected merge is caught by the confirm read"
}

test_forgejo_transient_confirm_read_failure_still_persists_authority() {
  local case_dir rc
  case_dir=$(make_forgejo_case forgejo-confirm-retry)
  printf '2\n' > "$case_dir/tea-post-merge-view-failures"

  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "forgejo-confirm-retry: a landed merge must not fail on a transient read-back failure"
  [ -e "$case_dir/tea-merged" ] || fail "forgejo-confirm-retry: the mock did not record the merge"
  [ "$(cat "$case_dir/tea-post-merge-view-failures")" = 0 ] \
    || fail "forgejo-confirm-retry: the confirmation read was not retried"
  [ "$(sed -n 6p "$case_dir/state/task-x1.merge-authority" 2>/dev/null || true)" = attended ] \
    || fail "forgejo-confirm-retry: the merge authority was not persisted: $(cat "$case_dir/state/task-x1.merge-authority" 2>/dev/null || true)"
  if grep -q "did not confirm" "$case_dir/stderr"; then
    fail "forgejo-confirm-retry: a landed merge was reported as unconfirmed"
  fi
  pass "fm-pr-merge retries a failed Forgejo confirmation read and persists the merge authority"
}

test_forgejo_merge_method_and_extra_args() {
  local case_dir rc merge_line style variant

  # With no method named, the repository's own default_merge_style decides,
  # whichever style it is.
  for style in squash rebase merge; do
    case_dir=$(make_forgejo_case "forgejo-default-method-$style")
    printf '{"default_merge_style":"%s"}\n' "$style" > "$case_dir/tea-repo.json"
    run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
      > "$case_dir/stdout" 2> "$case_dir/stderr" \
      || fail "forgejo-default-method-$style: an unqualified merge should succeed: $(cat "$case_dir/stderr")"
    [ "$(cat "$case_dir/tea-merge-do" 2>/dev/null)" = "$style" ] \
      || fail "forgejo-default-method-$style: the unqualified merge did not use the repository's default style"
  done

  # A named method wins without the repository read deciding anything.
  case_dir=$(make_forgejo_case forgejo-named-beats-default)
  printf '{"default_merge_style":"rebase"}\n' > "$case_dir/tea-repo.json"
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "forgejo-named-beats-default: --merge should succeed"
  [ "$(cat "$case_dir/tea-merge-do" 2>/dev/null)" = merge ] \
    || fail "forgejo-named-beats-default: a named method was overridden by the repository default"

  # An unreadable or unrecognized default refuses before any merge.
  for variant in unreadable unknown missing; do
    case_dir=$(make_forgejo_case "forgejo-default-$variant")
    case "$variant" in
      unreadable) : > "$case_dir/tea-repo-fails" ;;
      unknown) printf '{"default_merge_style":"manually-merged"}\n' > "$case_dir/tea-repo.json" ;;
      missing) printf '{"message":"not found"}\n' > "$case_dir/tea-repo.json" ;;
    esac
    set +e
    run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    expect_code 1 "$rc" "forgejo-default-$variant: a merge with no readable default style must be refused"
    assert_grep "the repository's default merge style could not be read" "$case_dir/stderr" \
      "forgejo-default-$variant: refusal did not name the unreadable default style"
    [ -z "$(tea_merge_line "$case_dir/tea.log")" ] \
      || fail "forgejo-default-$variant: a merge was attempted without a readable default style"
  done

  case_dir=$(make_forgejo_case forgejo-squash-method)
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" -- --squash \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "forgejo-squash-method: --squash should succeed"
  [ "$(cat "$case_dir/tea-merge-do" 2>/dev/null)" = squash ] \
    || fail "forgejo-squash-method: --squash did not select Do=squash"

  case_dir=$(make_forgejo_case forgejo-unsupported-arg)
  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" -- --admin-something-unrecognized \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "forgejo-unsupported-arg: an unrecognized extra argument must be refused"
  assert_grep 'extra merge arguments are not yet supported for Forgejo merges' "$case_dir/stderr" \
    "forgejo-unsupported-arg: refusal did not name the unsupported-argument reason"
  [ -z "$(tea_merge_line "$case_dir/tea.log")" ] \
    || fail "forgejo-unsupported-arg: a merge was attempted despite the unsupported argument"

  pass "fm-pr-merge maps --squash/--rebase to Forgejo's Do field, defaults to the repository's default merge style, and refuses any other extra argument"
}

test_gitlab_head_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-head-override)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" -- --sha "$MR_STALE_HEAD" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-head-override: fm-pr-merge should refuse a caller head override"
  assert_grep 'extra merge arguments must not override the head commit' "$case_dir/stderr" \
    "gitlab-head-override: refusal did not explain the head override"
  assert_no_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "gitlab-head-override: the URL was recorded before rejecting the head override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "gitlab-head-override: a head override armed a merge poll"
  [ ! -s "$case_dir/glab.log" ] || fail "gitlab-head-override: glab was invoked despite the head override"
  pass "fm-pr-merge refuses a GitLab head override before recording state"
}

test_github_still_forwards_sha_arg() {
  local case_dir rc
  case_dir=$(make_case github-sha-arg)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" dddddddddddddddddddddddddddddddddddddddd
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/44 -- --sha abc123 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-sha-arg: a caller --sha must be refused on GitHub too"
  assert_grep 'extra merge arguments must not override the head commit' "$case_dir/stderr" \
    "github-sha-arg: refusal did not name the head override"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-sha-arg: gh pr merge ran despite the head override"
  pass "fm-pr-merge refuses a caller --sha on GitHub because the head comes from the live read"
}

# --expected-head is optional. These cases pin the caller-supplied commit on
# every forge the script merges, and they refuse when that commit is not the
# one the forge write would bind.
test_expected_head_matching_reaches_each_forge() {
  local case_dir rc merge_line old long
  old=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  long=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
  [ "${#old}" -eq 40 ] || fail "expected-head-match: fixture sha is not 40 characters"
  [ "${#long}" -eq 64 ] || fail "expected-head-match: fixture sha is not 64 characters"

  case_dir=$(make_case expected-head-gh-match)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$old"
  : > "$case_dir/gh-axi.log"
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/201 \
    --expected-head "$old" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "expected-head-gh-match: a matching head should merge: $(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 201 example/repo --squash
  assert_grep "green at head $old" "$case_dir/stderr" \
    "expected-head-gh-match: the verified line did not name the supplied head"

  case_dir=$(make_case expected-head-gh-match-64)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$long"
  : > "$case_dir/gh-axi.log"
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/202 \
    --expected-head "$long" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "expected-head-gh-match-64: a 64-character head should merge: $(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 202 example/repo --squash

  case_dir=$(make_gitlab_case expected-head-gl-match)
  run_pr_merge "$case_dir" task-x1 "$MR_URL" --expected-head "$MR_HEAD" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "expected-head-gl-match: a matching head should merge: $(cat "$case_dir/stderr")"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  [ "$merge_line" = "GITLAB_HOST=$MR_HOST mr merge 7 -R $MR_PROJECT_URL --sha $MR_HEAD --yes" ] \
    || fail "expected-head-gl-match: the forge was not bound to the supplied head: '$merge_line'"

  case_dir=$(make_forgejo_case expected-head-fj-match)
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" --expected-head "$FJ_HEAD" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "expected-head-fj-match: a matching head should merge: $(cat "$case_dir/stderr")"
  merge_line=$(tea_merge_line "$case_dir/tea.log")
  case "$merge_line" in
    *"head_commit_id=$FJ_HEAD"*) : ;;
    *) fail "expected-head-fj-match: the forge was not bound to the supplied head: '$merge_line'" ;;
  esac
  pass "fm-pr-merge sends a matching --expected-head to each forge"
}

test_expected_head_mismatch_refuses_before_merge() {
  local case_dir rc old new
  old=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  new=dddddddddddddddddddddddddddddddddddddddd

  case_dir=$(make_case expected-head-gh-before)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$new"
  : > "$case_dir/gh-axi.log"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/203 \
    --expected-head "$old" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "expected-head-gh-before: a replaced head must refuse"
  assert_grep "the live head is \"$new\", not the expected head $old" "$case_dir/stderr" \
    "expected-head-gh-before: the refusal did not name both heads"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "expected-head-gh-before: gh pr merge ran after the live head moved"

  case_dir=$(make_gitlab_case expected-head-gl-before \
    head="$MR_STALE_HEAD" pipeline_sha="$MR_STALE_HEAD")
  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" --expected-head "$MR_HEAD" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "expected-head-gl-before: a replaced head must refuse"
  assert_grep "the live head is \"$MR_STALE_HEAD\", not the expected head $MR_HEAD" \
    "$case_dir/stderr" "expected-head-gl-before: the refusal did not name both heads"
  [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
    || fail "expected-head-gl-before: glab mr merge ran after the live head moved"

  case_dir=$(make_forgejo_case expected-head-fj-before head="$FJ_STALE_HEAD")
  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" --expected-head "$FJ_HEAD" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "expected-head-fj-before: a replaced head must refuse"
  assert_grep "the live head is \"$FJ_STALE_HEAD\", not the expected head $FJ_HEAD" \
    "$case_dir/stderr" "expected-head-fj-before: the refusal did not name both heads"
  [ -z "$(tea_merge_line "$case_dir/tea.log")" ] \
    || fail "expected-head-fj-before: a Forgejo merge ran after the live head moved"
  pass "fm-pr-merge refuses before any merge write when the live head differs from --expected-head"
}

test_expected_head_push_after_verify_is_refused_by_the_forge() {
  local case_dir rc merge_line old new
  old=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  new=dddddddddddddddddddddddddddddddddddddddd

  case_dir=$(make_case expected-head-gh-after)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$old"
  printf '%s\n' "$new" > "$case_dir/github-head-after-view"
  write_github_outcome "$case_dir" OPEN false false main
  : > "$case_dir/gh-axi.log"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/204 \
    --expected-head "$old" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "expected-head-gh-after: the forge must refuse the stale supplied head"
  assert_logged_gh_merge "$case_dir" 204 example/repo --squash
  assert_grep 'head out of date' "$case_dir/stderr" \
    "expected-head-gh-after: the forge refusal was not surfaced"
  assert_no_grep "--match-head-commit $new" "$case_dir/gh.log" \
    "expected-head-gh-after: the merge was bound to the head that landed after verification"

  case_dir=$(make_gitlab_case expected-head-gl-after)
  printf '%s\n' "$MR_STALE_HEAD" > "$case_dir/glab-head-after-view"
  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" --expected-head "$MR_HEAD" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "expected-head-gl-after: the forge must refuse the stale supplied head"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  [ "$merge_line" = "GITLAB_HOST=$MR_HOST mr merge 7 -R $MR_PROJECT_URL --sha $MR_HEAD --yes" ] \
    || fail "expected-head-gl-after: the forge was not asked for the supplied head: '$merge_line'"
  assert_grep 'head out of date' "$case_dir/stderr" \
    "expected-head-gl-after: the forge refusal was not surfaced"

  case_dir=$(make_forgejo_case expected-head-fj-after)
  printf '%s\n' "$FJ_STALE_HEAD" > "$case_dir/tea-head-after-view"
  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" --expected-head "$FJ_HEAD" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "expected-head-fj-after: the forge must refuse the stale supplied head"
  merge_line=$(tea_merge_line "$case_dir/tea.log")
  case "$merge_line" in
    *"head_commit_id=$FJ_HEAD"*) : ;;
    *) fail "expected-head-fj-after: the forge was not asked for the supplied head: '$merge_line'" ;;
  esac
  assert_no_grep "head_commit_id=$FJ_STALE_HEAD" "$case_dir/tea.log" \
    "expected-head-fj-after: the merge was bound to the head that landed after verification"
  assert_grep 'Forgejo did not confirm' "$case_dir/stderr" \
    "expected-head-fj-after: a rejected forge match was treated as merged"
  pass "fm-pr-merge binds the forge write to the supplied head after that head moves"
}

test_expected_head_later_preflight_does_not_adopt_a_new_head() {
  local case_dir rc old new
  old=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  new=dddddddddddddddddddddddddddddddddddddddd
  case_dir=$(make_case expected-head-gh-preflight)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$old"
  printf '%s\n' UNKNOWN MERGEABLE > "$case_dir/mergeable-sequence"
  printf '%s\n' "$old" "$new" > "$case_dir/github-head-by-call"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  FM_TEST_GH_MERGEABLE_SEQUENCE="$case_dir/mergeable-sequence" \
  FM_PR_GITHUB_MERGEABLE_RETRY_DELAY=0 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/205 \
    --expected-head "$old" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "expected-head-gh-preflight: a head that moves between preflight reads must refuse"
  assert_grep "the live head is \"$new\", not the expected head $old" "$case_dir/stderr" \
    "expected-head-gh-preflight: the later read was not compared with the supplied head"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "expected-head-gh-preflight: a later preflight adopted the new head and merged it"
  [ "$(grep -c '^pr view .*statusCheckRollup' "$case_dir/gh.log")" -eq 2 ] \
    || fail "expected-head-gh-preflight: expected exactly 2 live reads, got $(grep -c '^pr view .*statusCheckRollup' "$case_dir/gh.log")"
  pass "fm-pr-merge does not replace --expected-head when a later preflight reads a new head"
}

test_expected_head_bad_inputs_refuse_before_effects() {
  local case_dir rc name code needle full other
  full=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  other=dddddddddddddddddddddddddddddddddddddddd
  for name in malformed short7 short12 upper missing equals equals-full twice \
    conflict-sha conflict-match; do
    case_dir=$(make_case "expected-head-bad-$name")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" "$full"
    : > "$case_dir/gh-axi.log"
    case "$name" in
      malformed)
        code=2
        needle='full lowercase commit sha'
        set -- --expected-head 'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz'
        ;;
      short7)
        code=2
        needle='full lowercase commit sha'
        set -- --expected-head abc1234
        ;;
      short12)
        code=2
        needle='full lowercase commit sha'
        set -- --expected-head abcdef123456
        ;;
      upper)
        code=2
        needle='full lowercase commit sha'
        set -- --expected-head BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
        ;;
      missing)
        code=2
        needle='requires a full commit sha'
        set -- --expected-head
        ;;
      equals)
        code=2
        needle='separate full commit sha argument'
        set -- --expected-head=
        ;;
      equals-full)
        code=2
        needle='separate full commit sha argument'
        set -- "--expected-head=$full"
        ;;
      twice)
        code=2
        needle='may be specified only once'
        set -- --expected-head "$full" --expected-head "$other"
        ;;
      conflict-sha)
        code=1
        needle='must not override the head commit'
        set -- --expected-head "$full" -- --sha "$other"
        ;;
      conflict-match)
        code=1
        needle='must not override the head commit'
        set -- --expected-head "$full" -- --match-head-commit "$other"
        ;;
    esac
    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/210 "$@" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    expect_code "$code" "$rc" "expected-head-bad-$name"
    assert_grep "$needle" "$case_dir/stderr" \
      "expected-head-bad-$name: refusal did not name the bad input"
    assert_no_grep 'pr=' "$case_dir/state/task-x1.meta" \
      "expected-head-bad-$name: state was recorded before the bad input was refused"
    assert_absent "$case_dir/state/task-x1.check.sh" \
      "expected-head-bad-$name: a bad input armed a merge poll"
    assert_no_grep 'pr merge' "$case_dir/gh.log" \
      "expected-head-bad-$name: gh pr merge ran for a bad input"
  done
  pass "fm-pr-merge refuses a malformed, abbreviated, missing, or conflicting --expected-head before any effect"
}

test_expected_head_keeps_existing_refusals() {
  local case_dir rc head
  head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

  case_dir=$(make_case expected-head-draft)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  jq -c '.isDraft = true' "$case_dir/github-view.json" > "$case_dir/github-view.tmp"
  mv "$case_dir/github-view.tmp" "$case_dir/github-view.json"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/211 \
    --expected-head "$head" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "expected-head-draft: a draft must still refuse"
  assert_grep 'the pull request is a draft' "$case_dir/stderr" \
    "expected-head-draft: the draft refusal was skipped"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "expected-head-draft: gh pr merge ran on a draft"

  case_dir=$(make_case expected-head-red)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/212 \
    --expected-head "$head" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "expected-head-red: a red check must still refuse"
  assert_grep "check 'lint' is not green" "$case_dir/stderr" \
    "expected-head-red: the red check was skipped"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "expected-head-red: gh pr merge ran on a red check"

  case_dir=$(make_case expected-head-required)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_required "$case_dir" classic:ci classic:validate
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/213 \
    --expected-head "$head" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "expected-head-required: a missing required check must still refuse"
  assert_grep "required check 'validate' has not reported at head $head" "$case_dir/stderr" \
    "expected-head-required: the missing required check was skipped"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "expected-head-required: gh pr merge ran with a required check unreported"

  case_dir=$(make_case expected-head-hold)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  # Queued is enough. The hold check reads the captain-hold mark, and
  # fm-tasks-axi.sh refuses add --start without a dispatch record.
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-tasks-axi.sh" add task-x1 "Held merge" --kind ship --repo example \
    > "$case_dir/hold-add.out" 2> "$case_dir/hold-add.err" \
    || fail "expected-head-hold: could not add the task: $(cat "$case_dir/hold-add.err")"
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-captain-hold.sh" hold task-x1 --reason "captain merge approval pending" \
    > "$case_dir/hold.out" 2> "$case_dir/hold.err" \
    || fail "expected-head-hold: could not hold the task: $(cat "$case_dir/hold.err")"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/214 \
    --expected-head "$head" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "expected-head-hold: a captain hold must still refuse"
  assert_grep 'still held for the captain' "$case_dir/stderr" \
    "expected-head-hold: the hold refusal was skipped"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "expected-head-hold: gh pr merge ran while the task was held"

  case_dir=$(make_gitlab_case expected-head-review discussions=false)
  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" --expected-head "$MR_HEAD" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "expected-head-review: unresolved review discussion must still refuse"
  assert_grep 'blocking_discussions_resolved is "false", not true' "$case_dir/stderr" \
    "expected-head-review: the discussion refusal was skipped"
  [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
    || fail "expected-head-review: glab mr merge ran with review discussion open"

  case_dir=$(make_forgejo_case expected-head-fj-draft draft=true)
  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" --expected-head "$FJ_HEAD" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "expected-head-fj-draft: a Forgejo draft must still refuse"
  assert_grep 'the pull request is a draft' "$case_dir/stderr" \
    "expected-head-fj-draft: the draft refusal was skipped"
  [ -z "$(tea_merge_line "$case_dir/tea.log")" ] \
    || fail "expected-head-fj-draft: a Forgejo merge ran on a draft"

  case_dir=$(make_forgejo_case expected-head-fj-status)
  write_forgejo_status_json "$case_dir/tea-status.json" state=failure
  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" --expected-head "$FJ_HEAD" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "expected-head-fj-status: a failed combined status must still refuse"
  assert_grep 'the combined commit status is "failure", not success' "$case_dir/stderr" \
    "expected-head-fj-status: the status refusal was skipped"
  [ -z "$(tea_merge_line "$case_dir/tea.log")" ] \
    || fail "expected-head-fj-status: a Forgejo merge ran on a failed status"

  case_dir=$(make_case expected-head-away)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_away_record "$case_dir" --words 'merge task-x1 when green'
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/215 \
    --expected-head "$head" --allow-red lint \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "expected-head-away: an attended-only waiver while away must still refuse"
  assert_grep '--allow-red is attended-only' "$case_dir/stderr" \
    "expected-head-away: the authority refusal was skipped"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "expected-head-away: gh pr merge ran against the away authority"

  case_dir=$(make_case expected-head-identity)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  printf '\npr=https://github.com/example/repo/pull/99\n' >> "$case_dir/state/task-x1.meta"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/216 \
    --expected-head "$head" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "expected-head-identity: a different recorded PR must still refuse"
  assert_grep 'is bound to https://github.com/example/repo/pull/99' "$case_dir/stderr" \
    "expected-head-identity: the task identity refusal was skipped"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "expected-head-identity: gh pr merge ran for a task bound to another PR"
  pass "fm-pr-merge keeps draft, hold, review, check, authority, and identity refusals when --expected-head matches"
}

# --- durable merge outcome ---------------------------------------------------
# A merge that lands must leave a record outside the merging agent's memory.
# bin/fm-merge-outcome-lib.sh owns where that record goes; these cases pin the
# behavior through the real merge entrypoint.

# make_home_case <name> [<route> [<parent-home>]]: a case dir whose home is a
# secondmate home bound to a parent, or a plain main home when no route is
# given. Echoes the case dir; the home is "$case_dir/home".
make_home_case() {
  local name=$1 route=${2:-} parent=${3:-} case_dir home
  case_dir=$(make_case "$name")
  home="$case_dir/home"
  mkdir -p "$home" "$case_dir/wt"
  if [ -n "$route" ]; then
    printf '%s\n' mate-x >"$home/.fm-secondmate-home"
    {
      printf 'schema=fm-secondmate-parent.v1\n'
      printf 'route=%s\n' "$route"
      [ "$route" != local ] || printf 'parent_home=%s\n' "$parent"
    } >"$home/.fm-secondmate-parent"
  fi
  printf '%s\n' "$case_dir"
}

parent_reply_lines() {  # <file> <url>
  grep -c -F "$2" "$1" 2>/dev/null || true
}

test_secondmate_merge_reports_upward_once() {
  local case_dir replies url
  url=https://github.com/example/repo/pull/61
  case_dir=$(make_home_case secondmate-merge-reports remote)
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : >"$case_dir/gh-axi.log"
  replies="$case_dir/state/parent-replies.status"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "secondmate-merge-reports: merge failed"

  assert_grep "done [key=merged-task-x1]: merged task-x1 $url" <(sed -E 's/ \[at=[0-9]+\]//' "$replies") \
    "secondmate-merge-reports: the landed PR was not reported upward"
  [ "$(grep -c 'merged-task-x1' "$replies")" -eq 1 ] \
    || fail "secondmate-merge-reports: one merge produced more than one upward merge line"
  # The merge path registers the PR first, and that registration publishes the
  # child's ready line on the same channel from fm-pr-check itself.
  assert_grep "done [key=child-pr-task-x1]: child task-x1 PR ready: $url" <(sed -E 's/ \[at=[0-9]+\]//' "$replies") \
    "secondmate-merge-reports: the registration's ready line was not reported upward"

  # The same merge again: the forge accepts it in this fixture, so only the
  # at-most-once contract can keep the parent from being told twice.
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout2" 2>"$case_dir/stderr2" || fail "secondmate-merge-reports: repeat merge failed"
  [ "$(grep -c 'merged-task-x1' "$replies")" -eq 1 ] \
    || fail "secondmate-merge-reports: a repeat merge of the same PR duplicated the upward line"
  [ "$(parent_reply_lines "$replies" "$url")" -eq 2 ] \
    || fail "secondmate-merge-reports: a repeat merge changed the upward lines: $(cat "$replies")"
  pass "a merge a secondmate home performs itself is reported upward exactly once"
}

test_secondmate_merge_reports_on_the_local_route() {
  local case_dir parent_status url
  url=https://github.com/example/repo/pull/62
  case_dir=$(make_home_case secondmate-merge-local local "$TMP_ROOT/secondmate-merge-local/parent")
  mkdir -p "$TMP_ROOT/secondmate-merge-local/parent/state"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : >"$case_dir/gh-axi.log"
  parent_status="$TMP_ROOT/secondmate-merge-local/parent/state/mate-x.status"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "secondmate-merge-local: merge failed"

  assert_grep "done [key=merged-task-x1]: merged task-x1 $url" <(sed -E 's/ \[at=[0-9]+\]//' "$parent_status") \
    "secondmate-merge-local: the landed PR did not reach the parent home's channel"
  [ ! -e "$case_dir/state/parent-replies.status" ] \
    || fail "secondmate-merge-local: a local-route report also wrote the remote reply channel"
  pass "a locally routed secondmate home reports the landed PR into its parent's own channel"
}

test_failed_merge_reports_nothing() {
  local case_dir rc
  case_dir=$(make_home_case failed-merge-silent remote)
  add_gh_mocks_merge_fails "$case_dir"
  : >"$case_dir/gh-axi.log"

  set +e
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/63 \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "failed-merge-silent: a failed merge should propagate"
  # The registration's ready line is a fact of its own; only a merge line
  # would misreport the unlanded merge.
  assert_no_grep 'merged-task-x1' "$case_dir/state/parent-replies.status" \
    "failed-merge-silent: a merge that never landed was reported as landed"
  pass "a refused or failed merge reports no outcome"
}

test_gitlab_refusal_reports_nothing() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-refusal-silent state=merged)
  mkdir -p "$case_dir/home"
  printf '%s\n' mate-x >"$case_dir/home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' >"$case_dir/home/.fm-secondmate-parent"

  set +e
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-refusal-silent: a refused GitLab merge should exit non-zero"
  # Registration succeeds before the later GitLab pre-merge refusal, so the
  # PR-ready fact is expected; only a merged outcome would be false.
  assert_no_grep 'merged-task-x1' "$case_dir/state/parent-replies.status" \
    "gitlab-refusal-silent: a refused merge request was reported as landed"
  pass "a GitLab merge refused before the forge call reports no outcome"
}

test_gitlab_merge_reports_upward() {
  local case_dir url
  case_dir=$(make_gitlab_case gitlab-merge-reports)
  mkdir -p "$case_dir/home"
  printf '%s\n' mate-x >"$case_dir/home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' >"$case_dir/home/.fm-secondmate-parent"
  url=$MR_URL

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "gitlab-merge-reports: merge failed"

  assert_grep "done [key=merged-task-x1]: merged task-x1 $url" \
    <(sed -E 's/ \[at=[0-9]+\]//' "$case_dir/state/parent-replies.status") \
    "gitlab-merge-reports: a landed merge request was not reported upward"
  pass "a landed GitLab merge request is reported upward on the same channel"
}

test_queued_gitlab_merge_leaves_the_poll_armed() {
  local case_dir
  case_dir=$(make_gitlab_case queued-gitlab-merge)
  mkdir -p "$case_dir/home"
  : >"$case_dir/glab-stays-open"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" \
    || fail "queued-gitlab-merge: accepted merge command failed"

  assert_absent "$case_dir/state/.wake-queue" \
    "queued-gitlab-merge: a queued merge was reported as landed"
  [ -f "$case_dir/state/task-x1.check.sh" ] \
    || fail "queued-gitlab-merge: the merge poll was not left armed"
  [ ! -e "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "queued-gitlab-merge: a queued merge was marked as reported"
  pass "a queued GitLab merge stays silent and leaves confirmation to the armed poll"
}

test_main_home_merge_leaves_a_durable_wake() {
  local case_dir url
  url=https://github.com/example/repo/pull/64
  case_dir=$(make_home_case main-merge-wake)
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : >"$case_dir/gh-axi.log"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "main-merge-wake: merge failed"

  assert_grep "$url" "$case_dir/state/.wake-queue" \
    "main-merge-wake: a merge this home performed left no durable record naming the PR"
  [ "$(grep -c -F "$url" "$case_dir/state/.wake-queue")" -eq 1 ] \
    || fail "main-merge-wake: one merge produced more than one durable record"
  assert_absent "$case_dir/state/parent-replies.status" \
    "main-merge-wake: a main home wrote a parent reply channel it does not have"
  pass "a merge a main home performs itself leaves one durable wake naming the PR"
}

test_queued_github_merge_leaves_the_poll_armed() {
  local case_dir url
  url=https://github.com/example/repo/pull/66
  case_dir=$(make_home_case queued-github-merge)
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  write_github_outcome "$case_dir" OPEN false true main
  : >"$case_dir/gh-axi.log"

  FM_TEST_GH_MERGE_STATE=open FM_TEST_HOME="$case_dir/home" \
    run_pr_merge "$case_dir" task-x1 "$url" \
      >"$case_dir/stdout" 2>"$case_dir/stderr" \
    || fail "queued-github-merge: accepted merge command failed"

  assert_absent "$case_dir/state/.wake-queue" \
    "queued-github-merge: a queued merge was reported as landed"
  [ -f "$case_dir/state/task-x1.check.sh" ] \
    || fail "queued-github-merge: the merge poll was not left armed"
  [ ! -e "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "queued-github-merge: a queued merge was marked as reported"
  pass "a queued GitHub merge stays silent and leaves confirmation to the armed poll"
}

test_distinct_merged_prs_keep_distinct_wakes() {
  local case_dir first_url second_url
  first_url=https://github.com/example/repo/pull/68
  second_url=https://github.com/example/repo/pull/69
  case_dir=$(make_home_case distinct-merge-wakes)
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : >"$case_dir/gh-axi.log"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$first_url" \
    >"$case_dir/stdout-1" 2>"$case_dir/stderr-1" \
    || fail "distinct-merge-wakes: first merge failed"
  rm -f "$case_dir/state/task-x1.check.sh" \
    "$case_dir/state/task-x1.pr-poll" \
    "$case_dir/state/task-x1.pr-poll-registration"
  # The first PR's merge is already confirmed (the notified marker
  # fm_merge_outcome_report wrote), so the task's next PR is accepted with
  # pr= still bound to the first URL; no hand-edit of the recorded identity.
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$second_url" \
    >"$case_dir/stdout-2" 2>"$case_dir/stderr-2" \
    || fail "distinct-merge-wakes: second merge failed"

  [ "$(grep -c -F "$first_url" "$case_dir/state/.wake-queue")" -eq 1 ] \
    || fail "distinct-merge-wakes: first merge wake was missing or duplicated"
  [ "$(grep -c -F "$second_url" "$case_dir/state/.wake-queue")" -eq 1 ] \
    || fail "distinct-merge-wakes: second merge wake was missing or duplicated"
  FM_STATE_OVERRIDE="$case_dir/state" "$ROOT/bin/fm-wake-drain.sh" \
    >"$case_dir/drain.out" 2>"$case_dir/drain.err" \
    || fail "distinct-merge-wakes: wake drain failed"
  assert_grep "$first_url" "$case_dir/drain.out" \
    "distinct-merge-wakes: queue deduplication collapsed the first PR"
  assert_grep "$second_url" "$case_dir/drain.out" \
    "distinct-merge-wakes: queue deduplication collapsed the second PR"
  pass "distinct merged PRs for one task retain distinct captain-facing wakes"
}

test_uncommitted_marker_retry_is_never_silent() {
  local case_dir url count
  url=https://github.com/example/repo/pull/67
  case_dir=$(make_home_case uncommitted-wake-retry)
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : >"$case_dir/gh-axi.log"
  cat >"$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
case "${!#}" in
  *.pr-poll-merge-notified)
    if mkdir "$FM_TEST_MARKER_FAILURE.claim" 2>/dev/null; then
      exit 1
    fi
    ;;
esac
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$case_dir/fakebin/mv"
  export FM_TEST_MARKER_FAILURE="$case_dir/marker-failure"
  export FM_TEST_REAL_MV
  FM_TEST_REAL_MV=$(command -v mv)

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout-1" 2>"$case_dir/stderr-1" \
    || fail "uncommitted-wake-retry: landed merge was reported as failed"
  assert_grep 'could not record the outcome' "$case_dir/stderr-1" \
    "uncommitted-wake-retry: failed marker commit was not loud"
  [ -f "$case_dir/state/task-x1.check.sh" ] \
    || fail "uncommitted-wake-retry: failed commit disarmed the retry poll"
  count=$(grep -c -F "$url" "$case_dir/state/.wake-queue")
  [ "$count" -ge 1 ] \
    || fail "uncommitted-wake-retry: failed marker commit lost the durable outcome"
  [ ! -e "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "uncommitted-wake-retry: failed marker commit was treated as complete"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout-2" 2>"$case_dir/stderr-2" \
    || fail "uncommitted-wake-retry: retry failed"
  unset FM_TEST_MARKER_FAILURE FM_TEST_REAL_MV
  count=$(grep -c -F "$url" "$case_dir/state/.wake-queue")
  [ "$count" -ge 1 ] \
    || fail "uncommitted-wake-retry: retry left the merge silent"
  [ -f "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "uncommitted-wake-retry: retry did not commit the canonical marker"
  pass "an uncommitted marker retry preserves at least one durable outcome"
}

test_secondmate_without_parent_binding_is_loud() {
  local case_dir rc url
  url=https://github.com/example/repo/pull/65
  case_dir=$(make_home_case unbound-secondmate)
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : >"$case_dir/gh-axi.log"
  # A secondmate identity with no parent binding: exactly the seeding gap that
  # let three real merges land in silence.
  printf '%s\n' mate-x >"$case_dir/home/.fm-secondmate-home"

  set +e
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "unbound-secondmate: the merge itself landed and must not be reported as failed"
  assert_grep 'could not report it upward' "$case_dir/stderr" \
    "unbound-secondmate: a merge that could not be reported upward said nothing about it"
  assert_absent "$case_dir/state/.wake-queue" \
    "unbound-secondmate: a secondmate home fell back to the main-home record"
  pass "a secondmate home that cannot report upward says so instead of merging in silence"
}

test_github_behind_update_refuses_concurrent_head_change() {
  local case_dir rc scenario old_head raced_head updated_head actual_head
  old_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  raced_head=cccccccccccccccccccccccccccccccccccccccc
  updated_head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  for scenario in no-pin expected-pin; do
    case_dir=$(make_case "github-behind-concurrent-$scenario")
    add_gh_mocks "$case_dir" "$old_head"
    jq '.mergeStateStatus = "BEHIND"' "$case_dir/github-view.json" > "$case_dir/view.tmp"
    mv "$case_dir/view.tmp" "$case_dir/github-view.json"
    jq --arg head "$updated_head" '.mergeStateStatus = "CLEAN" | .headRefOid = $head' \
      "$case_dir/github-view.json" > "$case_dir/github-view-after-update.json"
    printf '%s\n' "$raced_head" > "$case_dir/github-head-after-view"
    printf '%s\n' "$updated_head" > "$case_dir/github-head-after-update"
    set -- --update-branch
    [ "$scenario" != expected-pin ] || set -- "$@" --expected-head "$old_head"
    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/6189 "$@" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    actual_head=$(cat "$case_dir/github-server-head")
    [ "$actual_head" = "$raced_head" ] \
      || fail "github-behind-concurrent-$scenario: unchecked replacement head was changed to $actual_head; expected $raced_head"
    expect_code 1 "$rc" "github-behind-concurrent-$scenario: a concurrent push must refuse"
    assert_grep 'HTTP 422' "$case_dir/stderr" \
      "github-behind-concurrent-$scenario: refusal must surface the head-mismatch response"
    assert_absent "$case_dir/github-update-done" \
      "github-behind-concurrent-$scenario: the rejected update changed the source branch"
    assert_no_grep 'pr merge' "$case_dir/gh.log" \
      "github-behind-concurrent-$scenario: merged after the head mismatch"
    [ "$(grep -c '/pulls/6189/update-branch' "$case_dir/gh.log")" -eq 1 ] \
      || fail "github-behind-concurrent-$scenario: must make one bound request without retrying the replacement head"
    assert_grep "api --method PUT repos/example/repo/pulls/6189/update-branch -f expected_head_sha=$old_head" \
      "$case_dir/gh.log" "github-behind-concurrent-$scenario: update did not name the preflight head"
  done
  pass "fm-pr-merge refuses a concurrent source-head change before updating, with or without --expected-head"
}

test_github_updated_head_other_refusals_stop_waiting() {
  local case_dir rc blocker waiting visibility visible_head reason reads advice violations=''
  local old_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  local new_head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  for visibility in updated delayed; do
    visible_head=$new_head
    [ "$visibility" != delayed ] || visible_head=$old_head
    for blocker in draft closed conflict required-source; do
      for waiting in pending missing; do
        case_dir=$(make_case "github-behind-blocker-$visibility-$blocker-$waiting")
        add_gh_mocks "$case_dir" "$old_head"
        write_github_required "$case_dir" ruleset:ci
        jq '.mergeStateStatus = "BEHIND"' "$case_dir/github-view.json" > "$case_dir/view.tmp"
        mv "$case_dir/view.tmp" "$case_dir/github-view.json"
        jq --arg head "$visible_head" --arg waiting "$waiting" --arg blocker "$blocker" '
          .mergeStateStatus = "CLEAN" | .headRefOid = $head |
          .statusCheckRollup = (if $waiting == "pending" then
            [{"__typename":"CheckRun","name":"ci","status":"IN_PROGRESS","conclusion":null}]
          else [] end) |
          if $blocker == "draft" then .isDraft = true
          elif $blocker == "closed" then .state = "CLOSED"
          elif $blocker == "conflict" then .mergeable = "CONFLICTING" | .mergeStateStatus = "DIRTY"
          else . end' "$case_dir/github-view.json" > "$case_dir/github-view-after-update.json"
        printf '%s\n' "$visible_head" > "$case_dir/github-head-after-update"
        case "$blocker" in
          draft) reason='the pull request is a draft' ;;
          closed) reason='state is "CLOSED", not open' ;;
          conflict) reason='mergeStateStatus is DIRTY' ;;
          required-source)
            reason='the branch protection summary for base branch main could not be read'
            printf '%s\n' 'HTTP 502: required-check source unavailable' > "$case_dir/github-branch-fail-after-update"
            ;;
        esac
        set +e
        FM_PR_GITHUB_MERGEABLE_RETRY_DELAY=1 \
          run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/6190 --update-branch \
          > "$case_dir/stdout" 2> "$case_dir/stderr"
        rc=$?
        set -e
        expect_code 1 "$rc" "$visibility-$blocker-$waiting: the updated head must refuse"
        assert_grep "$reason" "$case_dir/stderr" "$visibility-$blocker-$waiting: missing the actual refusal reason"
        assert_no_grep 'pr merge' "$case_dir/gh.log" "$visibility-$blocker-$waiting: merged despite a blocker"
        assert_absent "$case_dir/state/.control-task-x1.lock" "$visibility-$blocker-$waiting: task control lock remained held"
        assert_absent "$case_dir/state/.afk-contract.lock" "$visibility-$blocker-$waiting: away-authority lock remained held"
        [ "$(grep -c '/pulls/6190/update-branch' "$case_dir/gh.log")" -eq 1 ] \
          || fail "$visibility-$blocker-$waiting: the update request was repeated"
        reads=$(grep -c 'statusCheckRollup' "$case_dir/gh.log")
        advice=false
        if grep -q 'checks are not ready\|once its checks pass' "$case_dir/stderr"; then advice=true; fi
        printf 'observation: visibility=%s blocker=%s waiting=%s preflight_reads=%s retry_advice=%s\n' \
          "$visibility" "$blocker" "$waiting" "$reads" "$advice"
        # Collect every masking combination before reporting a regression failure.
        [ "$reads" -eq 2 ] || violations="$violations $visibility-$blocker-$waiting retried after the blocker;"
        [ "$advice" = false ] || violations="$violations $visibility-$blocker-$waiting suggested waiting for checks;"
      done
    done
  done
  [ -z "$violations" ] || fail "$violations"
  pass "fm-pr-merge immediately refuses draft, closed, conflicting, or unreadable updated heads despite pending or missing checks"
}

 test_forgejo_url_resolves_and_merges
 test_forgejo_combined_status_reads_every_page
 test_forgejo_unconfigured_ci_refuses_as_none
