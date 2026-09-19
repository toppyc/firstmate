#!/usr/bin/env bash
# Durable per-task record of EXTERNAL resources a worker created, plus the
# release path cleanup uses to shut them down again.
#
# Why a record at all: a worker that starts its own service container names it
# whatever it likes (sf-opstatus-pg for task stoneflow-operational-status-phase-gate),
# so the name is NOT derivable from the task id. Discovery by name pattern is
# therefore impossible, and guessing is forbidden: sibling task lanes and the
# captain's own development containers run on the same daemon, and stopping one
# of those would take out live work with no warning. The creator records what it
# created; cleanup releases exactly that and nothing else.
#
# This is a record, not a resource framework: one file, one line per resource,
# one release rule per kind. Adding a kind means adding one case here.
#
# Record file: <state>/<task-id>.resources, mode 0600, one link, on the state
# device. First line is the literal version header, then one entry per line:
#
#   fm-task-resources-v1
#   container sf-opstatus-pg
#
# Fail-closed reading: a record that is a symlink, has extra links, carries a
# different header, or holds any line that is not a valid "<kind> <name>" entry
# releases NOTHING. A name is accepted only as Docker's own container-name shape
# ([A-Za-z0-9][A-Za-z0-9_.-]*, at most 128 chars), which also keeps a name from
# ever being read as a CLI flag or a shell word.
#
# Callers must have sourced bin/fm-wake-lib.sh first (fm_lock_try_acquire,
# fm_lock_release), bin/fm-pr-lib.sh first (fm_pr_task_id_valid,
# fm_pr_file_device, fm_pr_file_link_count, fm_pr_private_file_valid,
# fm_pr_regular_destination_on_device_or_absent) and, for the release path,
# bin/fm-timeout-lib.sh (fm_run_timed).

FM_RESOURCE_RECORD_VERSION=fm-task-resources-v1
FM_RESOURCE_RELEASED=()
FM_RESOURCE_ABSENT=()
FM_RESOURCE_RETAINED=()
FM_RESOURCE_UNREACHABLE=()
# shellcheck disable=SC2034 # Read by callers of fm_resource_release_all (bin/fm-teardown.sh), not this lib.
FM_RESOURCE_RECORD_UNUSABLE=0

# Serialize one task's record against concurrent writers.
#
# Both mutators below are read-modify-write: they read the whole record, build a
# replacement and rename it into place. Two `fm-resource.sh record` calls for the
# same task - a worker bringing up Postgres and Redis in parallel, or two
# subagents of one task - would otherwise both read the same file and the later
# rename would win, silently dropping an entry while its command printed
# "recorded:" and exited 0. The lost container is then never released and never
# pointed at: the exact orphan this record exists to prevent, arrived at through
# a success report.
#
# The wait is deliberately BOUNDED and then fails loudly. A worker calls this
# mid-task, having just started a container it must record; blocking it forever
# on a stale lock would be a worse failure than the race - it strands the task
# and looks indistinguishable from a wedged worker. Failing lets the caller
# report and carry on, and the caller's own error path keeps the container's
# name in front of a human.
FM_RESOURCE_LOCK_WAIT_SECS=${FM_RESOURCE_LOCK_WAIT_SECS:-10}

fm_resource_lock_path() {  # <state> <task-id>
  printf '%s/.%s.resources.lock\n' "$1" "$2"
}

fm_resource_lock_acquire() {  # <state> <task-id>
  local lock waited=0
  lock=$(fm_resource_lock_path "$1" "$2")
  while ! fm_lock_try_acquire "$lock"; do
    if [ "$waited" -ge "$FM_RESOURCE_LOCK_WAIT_SECS" ]; then
      echo "error: another fm-resource.sh call is still holding $lock after ${FM_RESOURCE_LOCK_WAIT_SECS}s; not writing $2's record" >&2
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 0
}

fm_resource_lock_release() {  # <state> <task-id>
  fm_lock_release "$(fm_resource_lock_path "$1" "$2")"
}

fm_resource_record_path() {  # <state> <task-id>
  printf '%s/%s.resources\n' "$1" "$2"
}

fm_resource_kind_valid() {  # <kind>
  case "${1-}" in
    container) return 0 ;;
  esac
  return 1
}

fm_resource_name_valid() {  # <name>
  local name=${1-}
  local LC_ALL=C
  [ "${#name}" -le 128 ] || return 1
  case "$name" in
    ''|[!A-Za-z0-9]*|*[!A-Za-z0-9_.-]*) return 1 ;;
  esac
  return 0
}

# Print one "<kind> <name>" line per recorded resource.
# Returns 0 when the record is absent or entirely valid, 1 when it is present
# but unusable - in which case nothing is printed and the caller must release
# nothing.
fm_resource_entries() {  # <state> <task-id>
  local state=$1 id=$2 path line first=1 kind name out=
  fm_pr_task_id_valid "$id" || return 1
  path=$(fm_resource_record_path "$state" "$id")
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    return 0
  fi
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(fm_pr_file_link_count "$path")" = 1 ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$first" = 1 ]; then
      first=0
      [ "$line" = "$FM_RESOURCE_RECORD_VERSION" ] || return 1
      continue
    fi
    [ -n "$line" ] || continue
    kind=${line%% *}
    name=${line#* }
    [ "$kind" != "$line" ] || return 1
    fm_resource_kind_valid "$kind" || return 1
    fm_resource_name_valid "$name" || return 1
    out="$out$kind $name"$'\n'
  done < "$path"
  [ "$first" = 0 ] || return 1
  [ -z "$out" ] || printf '%s' "$out"
  return 0
}

# Append one resource to the task's record, creating it if needed. Idempotent:
# recording the same kind and name twice leaves one entry.
# Returns 0 on success, 2 on invalid input, 1 on a storage failure.
fm_resource_record_add() {  # <state> <task-id> <kind> <name>
  local rc
  fm_pr_task_id_valid "${2-}" || return 2
  fm_resource_kind_valid "${3-}" || return 2
  fm_resource_name_valid "${4-}" || return 2
  [ -d "${1-}" ] && [ ! -L "${1-}" ] || return 1
  fm_resource_lock_acquire "$1" "$2" || return 1
  fm_resource_record_add_locked "$@"
  rc=$?
  fm_resource_lock_release "$1" "$2"
  return "$rc"
}

fm_resource_record_add_locked() {  # <state> <task-id> <kind> <name>
  local state=$1 id=$2 kind=$3 name=$4 path device tmp existing
  path=$(fm_resource_record_path "$state" "$id")
  device=$(fm_pr_file_device "$state") || return 1
  fm_pr_regular_destination_on_device_or_absent "$path" "$device" || return 1
  # Command substitution strips the trailing newline, so both the duplicate test
  # and the rewrite below put it back rather than running entries together.
  existing=$(fm_resource_entries "$state" "$id") || return 1
  case $'\n'"$existing"$'\n' in
    *$'\n'"$kind $name"$'\n'*) return 0 ;;
  esac
  tmp=$(mktemp "$state/.fm-task-resources.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  {
    printf '%s\n' "$FM_RESOURCE_RECORD_VERSION"
    [ -z "$existing" ] || printf '%s\n' "$existing"
    printf '%s %s\n' "$kind" "$name"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  fm_pr_regular_destination_on_device_or_absent "$path" "$device" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path" || { rm -f -- "$tmp"; return 1; }
  return 0
}

# Drop one resource from the task's record; removes the record when it empties.
# Returns 0 when the entry is gone afterwards, 2 on invalid input, 1 on a
# storage failure or an unusable record.
fm_resource_record_remove() {  # <state> <task-id> <kind> <name>
  local rc
  fm_pr_task_id_valid "${2-}" || return 2
  fm_resource_kind_valid "${3-}" || return 2
  fm_resource_name_valid "${4-}" || return 2
  fm_resource_lock_acquire "$1" "$2" || return 1
  fm_resource_record_remove_locked "$@"
  rc=$?
  fm_resource_lock_release "$1" "$2"
  return "$rc"
}

fm_resource_record_remove_locked() {  # <state> <task-id> <kind> <name>
  local state=$1 id=$2 kind=$3 name=$4 path device tmp existing kept line
  path=$(fm_resource_record_path "$state" "$id")
  existing=$(fm_resource_entries "$state" "$id") || return 1
  [ -n "$existing" ] || return 0
  kept=
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$line" != "$kind $name" ] || continue
    kept="$kept$line"$'\n'
  done <<< "$existing"
  if [ -z "$kept" ]; then
    rm -f -- "$path" || return 1
    return 0
  fi
  device=$(fm_pr_file_device "$state") || return 1
  tmp=$(mktemp "$state/.fm-task-resources.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  { printf '%s\n' "$FM_RESOURCE_RECORD_VERSION"; printf '%s' "$kept"; } > "$tmp" \
    || { rm -f -- "$tmp"; return 1; }
  fm_pr_regular_destination_on_device_or_absent "$path" "$device" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path" || { rm -f -- "$tmp"; return 1; }
  return 0
}

# Stop one recorded container. Echoes a short outcome word:
#   released     - the container was running and is now stopped
#   absent       - the daemon answered and has no such container; nothing to stop
#   retained     - the daemon answered and the stop failed; the container is
#                  known to be there and could not be released
#   unreachable  - docker could not be asked at all (no binary, or the daemon did
#                  not answer); nothing about the container is proven either way
#
# Absence is a positive finding, never a default: `docker container inspect`
# exits non-zero both for "no such container" and for "cannot connect to the
# daemon", and only the first may be reported as absent - the caller retires the
# record on `absent`, so mistaking a downed daemon for a stopped container
# destroys the operator's only pointer to a container that is still running.
# `unreachable` and `retained` are kept apart for the mirror-image reason: not
# being able to ask is no more evidence that a container is running than that it
# is gone, so a caller that refuses over a live container must not refuse over a
# daemon it could not reach. Both keep the record; only `retained` proves the
# container is there. The daemon probe costs a second docker call only after
# inspect has already failed.

# Bound for one docker call. A daemon that is DOWN refuses the socket and fails
# fast; a daemon that is WEDGED accepts the connection and never answers, which
# is a normal outcome of the memory pressure this whole record exists for, and
# the docker CLI puts no deadline on that request. Cleanup that blocks there is
# indistinguishable from the wedge itself.
FM_RESOURCE_DOCKER_TIMEOUT=${FM_RESOURCE_DOCKER_TIMEOUT:-20}

# Run one docker call under the shared hard bound. Exit 124 means the bound was
# hit, which every caller below reads as `unreachable`.
#
# The ABSENCE of a usable bound is itself a failure, reported as 124 rather than
# degraded into an unbounded call: a bound of 0 disables the deadline in both
# `timeout` and the perl fallback, and a missing fm_run_timed means the sourcing
# contract above was not met. Either way docker is never asked, because an
# unbounded ask is exactly the hang this exists to prevent and it would report
# success while doing it.
fm_resource_run_docker() {  # <docker-args...>
  case "$FM_RESOURCE_DOCKER_TIMEOUT" in
    ''|*[!0-9]*) return 124 ;;
  esac
  [ "$FM_RESOURCE_DOCKER_TIMEOUT" -gt 0 ] || return 124
  command -v fm_run_timed >/dev/null 2>&1 || return 124
  fm_run_timed "$FM_RESOURCE_DOCKER_TIMEOUT" docker "$@"
}

fm_resource_release_container() {  # <name>
  local name=$1 rc=0
  command -v docker >/dev/null 2>&1 || { printf 'unreachable\n'; return 1; }
  fm_resource_run_docker container inspect "$name" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 124 ]; then
    printf 'unreachable\n'
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    if fm_resource_run_docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
      printf 'absent\n'
      return 0
    fi
    printf 'unreachable\n'
    return 1
  fi
  rc=0
  fm_resource_run_docker stop "$name" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'released\n'
    return 0
  fi
  if [ "$rc" -eq 124 ]; then
    printf 'unreachable\n'
    return 1
  fi
  printf 'retained\n'
  return 1
}

# Release every resource recorded for the task, filling FM_RESOURCE_RELEASED,
# FM_RESOURCE_ABSENT, FM_RESOURCE_RETAINED and FM_RESOURCE_UNREACHABLE with
# "<kind> <name>" entries. Returns 0 when nothing is left holding resources
# (including "record absent" and "every recorded resource already gone"), 1 when
# at least one entry could not be released or the record itself was unusable -
# which the caller tells apart through FM_RESOURCE_RECORD_UNUSABLE. A caller
# deciding whether to REFUSE over an entry must read FM_RESOURCE_RETAINED alone:
# FM_RESOURCE_UNREACHABLE proves nothing about the resource, only about docker.
fm_resource_release_all() {  # <state> <task-id>
  local entries line kind name outcome rc=0
  FM_RESOURCE_RELEASED=()
  FM_RESOURCE_ABSENT=()
  FM_RESOURCE_RETAINED=()
  FM_RESOURCE_UNREACHABLE=()
  FM_RESOURCE_RECORD_UNUSABLE=0
  # shellcheck disable=SC2034 # Read by bin/fm-teardown.sh.
  entries=$(fm_resource_entries "$1" "$2") || { FM_RESOURCE_RECORD_UNUSABLE=1; return 1; }
  [ -n "$entries" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    kind=${line%% *}
    name=${line#* }
    case "$kind" in
      container) outcome=$(fm_resource_release_container "$name") || rc=1 ;;
      *) outcome=retained; rc=1 ;;
    esac
    case "$outcome" in
      released) FM_RESOURCE_RELEASED+=("$kind $name") ;;
      absent) FM_RESOURCE_ABSENT+=("$kind $name") ;;
      unreachable) FM_RESOURCE_UNREACHABLE+=("$kind $name") ;;
      *) FM_RESOURCE_RETAINED+=("$kind $name") ;;
    esac
  done <<< "$entries"
  return "$rc"
}
