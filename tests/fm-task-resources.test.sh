#!/usr/bin/env bash
# Behavior tests for bin/fm-resource.sh and the record contract in
# bin/fm-resource-lib.sh.
#
# A worker invents its own container name (sf-opstatus-pg for task
# stoneflow-operational-status-phase-gate), so cleanup cannot derive it and must
# never guess: the creator records what it created, and cleanup releases exactly
# that record. These cases pin the record end of that contract - what may be
# recorded, what the record looks like on disk, and that a record which cannot be
# trusted yields nothing rather than a guess. tests/fm-teardown.test.sh pins the
# release end.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RESOURCE="$ROOT/bin/fm-resource.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-resources)

# Fresh home with an empty state dir. Echoes the home path.
make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

run_resource() {  # <home> <args...>
  local home=$1; shift
  FM_HOME="$home" "$RESOURCE" "$@"
}

test_record_then_list_round_trips() {
  local home out
  home=$(make_home round-trip)
  run_resource "$home" record task-a container sf-a-pg >/dev/null \
    || fail "recording a container failed"
  run_resource "$home" record task-a container sf-a-redis >/dev/null \
    || fail "recording a second container failed"
  out=$(run_resource "$home" list task-a) || fail "listing the record failed"
  assert_contains "$out" "container sf-a-pg" "the first recorded container is missing from the list"
  assert_contains "$out" "container sf-a-redis" "the second recorded container is missing from the list"
  pass "fm-resource.sh: records and lists a task's containers"
}

test_record_is_idempotent() {
  local home count
  home=$(make_home idempotent)
  run_resource "$home" record task-a container sf-a-pg >/dev/null
  run_resource "$home" record task-a container sf-a-pg >/dev/null \
    || fail "re-recording the same container failed"
  count=$(run_resource "$home" list task-a | grep -c 'container sf-a-pg')
  [ "$count" = 1 ] || fail "re-recording duplicated the entry ($count copies)"
  pass "fm-resource.sh: recording the same container twice keeps one entry"
}

test_record_is_private_and_versioned() {
  local home record mode
  home=$(make_home on-disk)
  run_resource "$home" record task-a container sf-a-pg >/dev/null
  record="$home/state/task-a.resources"
  assert_present "$record" "the record was not written to state/<id>.resources"
  [ ! -L "$record" ] || fail "the record is a symlink"
  assert_grep "fm-task-resources-v1" "$record" "the record has no version header"
  assert_grep "container sf-a-pg" "$record" "the record has no entry for the container"
  if [ "$(uname)" = Darwin ]; then mode=$(stat -f %Lp "$record"); else mode=$(stat -c %a "$record"); fi
  [ "$mode" = 600 ] || fail "the record is mode $mode, not 600"
  pass "fm-resource.sh: the record is a private, versioned state file"
}

test_record_refuses_a_name_that_could_be_a_flag() {
  local home out rc
  home=$(make_home flag-name)
  set +e
  out=$(run_resource "$home" record task-a container --force 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a flag-shaped container name was accepted"
  assert_absent "$home/state/task-a.resources" "a record was written for a refused name"
  assert_contains "$out" "error:" "the refusal printed no error"
  pass "fm-resource.sh: refuses a container name that could be read as a flag"
}

test_record_refuses_unsafe_and_unknown_inputs() {
  local home rc
  home=$(make_home unsafe-inputs)
  for bad in 'sf a pg' 'sf/../pg' '' '*'; do
    set +e
    run_resource "$home" record task-a container "$bad" >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "container name '$bad' was accepted"
  done
  set +e
  run_resource "$home" record task-a volume some-volume >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unsupported resource kind was accepted"
  set +e
  run_resource "$home" record ../escape container sf-a-pg >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a path-unsafe task id was accepted"
  assert_absent "$home/state/task-a.resources" "a record was written despite every input being refused"
  pass "fm-resource.sh: refuses unsafe names, unknown kinds, and unsafe task ids"
}

test_forget_drops_an_entry_and_retires_an_empty_record() {
  local home out
  home=$(make_home forget)
  run_resource "$home" record task-a container sf-a-pg >/dev/null
  run_resource "$home" record task-a container sf-a-redis >/dev/null
  run_resource "$home" forget task-a container sf-a-pg >/dev/null \
    || fail "forgetting a recorded container failed"
  out=$(run_resource "$home" list task-a)
  assert_not_contains "$out" "sf-a-pg" "the forgotten container is still listed"
  assert_contains "$out" "sf-a-redis" "forgetting one entry dropped the other"
  run_resource "$home" forget task-a container sf-a-redis >/dev/null
  assert_absent "$home/state/task-a.resources" "an emptied record was left behind"
  pass "fm-resource.sh: forget drops one entry and retires an emptied record"
}

test_unusable_record_yields_nothing() {
  local home record rc out
  home=$(make_home unusable)
  record="$home/state/task-a.resources"

  printf 'container sf-a-pg\n' > "$record"
  set +e
  out=$(run_resource "$home" list task-a 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a record with no version header was read"
  assert_not_contains "$out" "container sf-a-pg" "an unversioned record still yielded an entry"

  printf 'fm-task-resources-v1\nvolume sf-a-vol\n' > "$record"
  set +e
  out=$(run_resource "$home" list task-a 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a record holding an unknown kind was read"

  printf 'fm-task-resources-v1\ncontainer sf-a-pg\nnonsense\n' > "$record"
  set +e
  out=$(run_resource "$home" list task-a 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a record holding a malformed line was read"
  assert_not_contains "$out" "container sf-a-pg" "a partly malformed record still yielded its valid entry"

  rm -f "$record"
  printf 'fm-task-resources-v1\ncontainer sf-a-pg\n' > "$home/state/elsewhere"
  ln -s "$home/state/elsewhere" "$record"
  set +e
  out=$(run_resource "$home" list task-a 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a symlinked record was read"
  assert_not_contains "$out" "container sf-a-pg" "a symlinked record still yielded an entry"
  pass "fm-resource.sh: an unusable record yields nothing rather than a guess"
}

test_record_refuses_to_append_to_an_unusable_record() {
  local home record rc
  home=$(make_home no-append)
  record="$home/state/task-a.resources"
  printf 'fm-task-resources-v1\nnonsense\n' > "$record"
  set +e
  run_resource "$home" record task-a container sf-a-pg >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an entry was appended to an unusable record"
  assert_no_grep "container sf-a-pg" "$record" "an unusable record was overwritten"
  pass "fm-resource.sh: refuses to append to a record it cannot read"
}

test_record_is_per_task() {
  local home out
  home=$(make_home per-task)
  run_resource "$home" record task-a container sf-a-pg >/dev/null
  run_resource "$home" record task-b container sf-b-pg >/dev/null
  out=$(run_resource "$home" list task-a)
  assert_contains "$out" "sf-a-pg" "task-a's own container is missing from its record"
  assert_not_contains "$out" "sf-b-pg" "task-b's container leaked into task-a's record"
  out=$(run_resource "$home" list task-b)
  assert_not_contains "$out" "sf-a-pg" "task-a's container leaked into task-b's record"
  pass "fm-resource.sh: one task's record never names another task's resources"
}

test_list_of_an_unrecorded_task_is_empty_and_clean() {
  local home out rc
  home=$(make_home no-record)
  set +e
  out=$(run_resource "$home" list task-a 2>&1); rc=$?
  set -e
  expect_code 0 "$rc" "listing a task that recorded nothing should succeed"
  [ -z "$out" ] || fail "listing a task that recorded nothing printed: $out"
  pass "fm-resource.sh: a task that recorded nothing lists nothing"
}

test_brief_tells_workers_to_record_what_they_start() {
  local home brief kind
  home=$(make_home brief)
  mkdir -p "$home/data"
  for kind in ship scout; do
    if [ "$kind" = ship ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "brief-$kind" demorepo --mode no-mistakes >/dev/null \
        || fail "scaffolding a $kind brief failed"
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "brief-$kind" demorepo --scout >/dev/null \
        || fail "scaffolding a $kind brief failed"
    fi
    brief="$home/data/brief-$kind/brief.md"
    assert_grep "bin/fm-resource.sh record brief-$kind container" "$brief" \
      "the $kind brief does not tell the worker how to record a container it starts"
    assert_grep "will never guess" "$brief" \
      "the $kind brief does not say cleanup releases only what was recorded"
  done
  pass "fm-brief.sh: ship and scout briefs tell workers to record what they start"
}

test_record_then_list_round_trips
test_record_is_idempotent
test_record_is_private_and_versioned
test_record_refuses_a_name_that_could_be_a_flag
test_record_refuses_unsafe_and_unknown_inputs
test_forget_drops_an_entry_and_retires_an_empty_record
test_unusable_record_yields_nothing
test_record_refuses_to_append_to_an_unusable_record
test_record_is_per_task
test_list_of_an_unrecorded_task_is_empty_and_clean
test_brief_tells_workers_to_record_what_they_start
