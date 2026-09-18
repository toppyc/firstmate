#!/usr/bin/env bash
# Record an external resource a task created, so cleanup can release it later.
# A worker that starts its own service container names it whatever it likes, and
# that name cannot be derived from the task id, so cleanup never guesses: it
# releases exactly what is recorded here and nothing else. Record the resource as
# soon as you create it - an unrecorded container outlives its task forever.
# Usage: fm-resource.sh record <task-id> container <name>
#        fm-resource.sh forget <task-id> container <name>
#        fm-resource.sh list <task-id>
#   record  add the resource to the task's durable record (idempotent)
#   forget  drop it again, e.g. after you stopped it yourself
#   list    print the task's recorded resources, one "<kind> <name>" per line
# Only `container` (a Docker container, released with `docker stop`) is a
# supported kind today.
# bin/fm-resource-lib.sh owns the record format, the name rules, and the release
# contract; bin/fm-teardown.sh releases the record during task cleanup.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-resource-lib.sh
. "$SCRIPT_DIR/fm-resource-lib.sh"

ACTION=${1:-}
ID=${2:-}
[ -n "$ACTION" ] && [ -n "$ID" ] || { usage >&2; exit 2; }
fm_pr_task_id_valid "$ID" || { echo "error: invalid task id: $ID" >&2; exit 2; }
[ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "error: state directory is unavailable: $STATE" >&2; exit 1; }

case "$ACTION" in
  record|forget)
    [ "$#" -eq 4 ] || { usage >&2; exit 2; }
    KIND=$3
    NAME=$4
    fm_resource_kind_valid "$KIND" \
      || { echo "error: unsupported resource kind: $KIND (supported: container)" >&2; exit 2; }
    fm_resource_name_valid "$NAME" \
      || { echo "error: unsupported $KIND name: $NAME (expected [A-Za-z0-9][A-Za-z0-9_.-]*, at most 128 characters)" >&2; exit 2; }
    if [ "$ACTION" = record ]; then
      fm_resource_record_add "$STATE" "$ID" "$KIND" "$NAME" \
        || { echo "error: could not record $KIND $NAME for task $ID" >&2; exit 1; }
      printf 'recorded: %s %s (task %s)\n' "$KIND" "$NAME" "$ID"
    else
      fm_resource_record_remove "$STATE" "$ID" "$KIND" "$NAME" \
        || { echo "error: could not drop $KIND $NAME from task $ID" >&2; exit 1; }
      printf 'forgot: %s %s (task %s)\n' "$KIND" "$NAME" "$ID"
    fi
    ;;
  list)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    ENTRIES=$(fm_resource_entries "$STATE" "$ID") \
      || { echo "error: task $ID has an unusable resource record at $(fm_resource_record_path "$STATE" "$ID")" >&2; exit 1; }
    [ -z "$ENTRIES" ] || printf '%s\n' "$ENTRIES"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
