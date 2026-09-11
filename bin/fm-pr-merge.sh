#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
#
# --no-worker merges a PR firstmate opened itself for a backlog item that never
# had a worker: no crewmate, no worktree, no runtime metadata, and so nothing to
# tear down. The recorded pr= and pr_head= exist only so bin/fm-teardown.sh can
# verify landed work, so with no worker there is no consumer for them and the
# flag skips the bin/fm-pr-check.sh recording step entirely; firstmate updates
# the backlog item on completion as it does for any other finished work.
# The flag is an assertion this script verifies rather than trusts: it refuses
# when the task has runtime metadata at state/<task-id>.meta, a brief or report
# directory at data/<task-id>/, or a status log at state/<task-id>.status.
# data/<task-id>/ is the durable signal: it holds the brief bin/fm-spawn.sh
# refuses to launch without, and bin/fm-teardown.sh does not remove it, so it
# still identifies a crew-shipped task after teardown. The metadata and the
# status log say a worker exists right now, and teardown removes both, so
# neither is relied on to identify a task whose worker has already been torn
# down. Absent metadata alone never relaxes anything - without --no-worker the
# refusal is exactly as it was, so a mistyped task id still stops the merge.
#
# Known limitation: under --no-worker the task id is used only for that guard,
# so a mistyped id paired with a real PR URL merges that PR without recording
# pr= against the task that actually owns it. The recording is a fast path for
# teardown rather than its only evidence: bin/fm-teardown.sh also resolves the
# PR from the branch name and then falls back to a content check against the
# default branch, and refuses to return a worktree when all of those are
# inconclusive, so the owner task's cleanup stops rather than discarding work.
# Usage: fm-pr-merge.sh [--no-worker] <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  # The whole leading comment block, ending at the first non-comment line.
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

NO_WORKER=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --no-worker) NO_WORKER=1; shift ;;
    *) break ;;
  esac
done

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"

if [ "$NO_WORKER" = 1 ]; then
  # Every per-task artifact a worker leaves behind, any one of which means
  # --no-worker is being pointed at the wrong task. data/<id>/ is the durable
  # one: it holds the brief bin/fm-spawn.sh refuses to launch without, and
  # bin/fm-teardown.sh does not remove it, so it still identifies a crew-shipped
  # task after teardown. The metadata and state/<id>.status say a worker exists
  # right now, and teardown removes both, so neither is relied on once the
  # worker is gone.
  worker_record=
  if [ -e "$META" ] || [ -L "$META" ]; then
    worker_record="state/$ID.meta"
  elif [ -e "$DATA/$ID" ] || [ -L "$DATA/$ID" ]; then
    worker_record="data/$ID"
  elif [ -e "$STATE/$ID.status" ] || [ -L "$STATE/$ID.status" ]; then
    worker_record="state/$ID.status"
  fi
  if [ -n "$worker_record" ]; then
    echo "error: --no-worker refused: $ID has a worker record at $worker_record" >&2
    exit 1
  fi
  printf 'no task record: %s has no worker; nothing to record for teardown\n' "$ID"
else
  if [ ! -f "$META" ] || [ -L "$META" ]; then
    echo "error: task metadata is unavailable" >&2
    exit 1
  fi

  "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
  grep -qxF "pr=$URL" "$META" || {
    echo "error: PR metadata recording failed" >&2
    exit 1
  }
fi

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
