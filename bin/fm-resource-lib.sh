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
# Callers must have sourced bin/fm-pr-lib.sh first (fm_pr_task_id_valid,
# fm_pr_file_device, fm_pr_file_link_count, fm_pr_private_file_valid,
# fm_pr_regular_destination_on_device_or_absent).

FM_RESOURCE_RECORD_VERSION=fm-task-resources-v1
FM_RESOURCE_RELEASED=()
FM_RESOURCE_ABSENT=()
FM_RESOURCE_RETAINED=()
# shellcheck disable=SC2034 # Read by callers of fm_resource_release_all (bin/fm-teardown.sh), not this lib.
FM_RESOURCE_RECORD_UNUSABLE=0

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
  local state=$1 id=$2 kind=$3 name=$4 path device tmp existing
  fm_pr_task_id_valid "$id" || return 2
  fm_resource_kind_valid "$kind" || return 2
  fm_resource_name_valid "$name" || return 2
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
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
  local state=$1 id=$2 kind=$3 name=$4 path device tmp existing kept line
  fm_pr_task_id_valid "$id" || return 2
  fm_resource_kind_valid "$kind" || return 2
  fm_resource_name_valid "$name" || return 2
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
#   released  - the container was running and is now stopped
#   absent    - the daemon answered and has no such container; nothing to stop
#   retained  - could not be released (no docker, an unreachable daemon, or the
#               stop failed)
#
# Absence is a positive finding, never a default: `docker container inspect`
# exits non-zero both for "no such container" and for "cannot connect to the
# daemon", and only the first may be reported as absent - the caller retires the
# record on `absent`, so mistaking a downed daemon for a stopped container
# destroys the operator's only pointer to a container that is still running.
# Anything that cannot PROVE absence is retained. The daemon probe costs a
# second docker call only after inspect has already failed.
fm_resource_release_container() {  # <name>
  local name=$1
  command -v docker >/dev/null 2>&1 || { printf 'retained\n'; return 1; }
  if ! docker container inspect "$name" >/dev/null 2>&1; then
    if docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
      printf 'absent\n'
      return 0
    fi
    printf 'retained\n'
    return 1
  fi
  if docker stop "$name" >/dev/null 2>&1; then
    printf 'released\n'
    return 0
  fi
  printf 'retained\n'
  return 1
}

# Release every resource recorded for the task, filling FM_RESOURCE_RELEASED,
# FM_RESOURCE_ABSENT and FM_RESOURCE_RETAINED with "<kind> <name>" entries.
# Returns 0 when nothing is left holding resources (including "record absent"
# and "every recorded resource already gone"), 1 when at least one entry could
# not be released or the record itself was unusable - which the caller tells
# apart through FM_RESOURCE_RECORD_UNUSABLE.
fm_resource_release_all() {  # <state> <task-id>
  local entries line kind name outcome rc=0
  FM_RESOURCE_RELEASED=()
  FM_RESOURCE_ABSENT=()
  FM_RESOURCE_RETAINED=()
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
      *) FM_RESOURCE_RETAINED+=("$kind $name") ;;
    esac
  done <<< "$entries"
  return "$rc"
}
