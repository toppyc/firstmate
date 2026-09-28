#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop after `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read still only
# costs the loop's existing one-second inter-poll sleep to confirm - not an
# extra full cycle on top of that.
test_already_settled_pane_costs_one_confirm_sleep() {
  local rec id out status start end elapsed
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  start=$(date +%s)
  out=$(run_settle_spawn "$id")
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  [ "$elapsed" -le 5 ] || fail "already-settled pane took ${elapsed}s to confirm - expected close to the single inter-poll sleep"
  pass "an already-settled pane confirms via the existing inter-poll sleep, not an extra full cycle"
}

# When the project argument is itself a linked worktree, the repository's real
# primary checkout differs from that argument and is a real top-level, so the
# path checks alone accept it. Spawn must still refuse it before refreshing its
# base or writing any harness turn-end wiring there: a Claude hook left in a
# primary checkout's .claude/settings.local.json fires for every Claude session
# in every linked worktree of that repository.
test_primary_checkout_behind_a_linked_project_arg_is_refused() {
  local rec id out status primary head_before
  id=settle-primary-behind-linked-z3
  rec=$(make_settle_case settle-primary-behind-linked "$id" 0)
  read_settle_record "$rec"
  primary=$PROJ_DIR
  head_before=$(git -C "$primary" rev-parse HEAD)
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  # The linked worktree stands in as the project argument; the pane settles in
  # the primary checkout.
  PROJ_DIR=$WT_DIR
  WT_DIR=$primary

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted the primary checkout behind a linked-worktree project argument: $out"
  assert_contains "$out" "primary checkout of the project repository" \
    "spawn did not name the primary-checkout refusal"
  [ ! -e "$primary/.claude/settings.local.json" ] \
    || fail "spawn wrote harness turn-end wiring into the primary checkout"
  [ "$(git -C "$primary" rev-parse HEAD)" = "$head_before" ] \
    || fail "spawn moved the primary checkout's HEAD"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "spawn recorded a task in the primary checkout"
  pass "a primary checkout reached through a linked-worktree project argument is refused before any wiring"
}

# On a case-insensitive filesystem a project argument spelled with different
# case names the same primary checkout, but pwd -P keeps the caller's spelling
# while the pane reports the on-disk one. Spawn must recognize the pane still
# sitting in the primary checkout as the primary checkout, not as a worktree.
test_case_variant_project_arg_does_not_accept_the_primary() {
  local rec id out status primary variant head_before
  id=settle-case-variant-z4
  rec=$(make_settle_case settle-case-variant "$id" 0)
  read_settle_record "$rec"
  primary=$PROJ_DIR
  variant="${primary%/*}/PROJECT"
  if ! [ -d "$variant" ] || ! [ "$variant" -ef "$primary" ]; then
    printf 'ok - SKIP case-variant project argument: this filesystem is case-sensitive\n'
    return 0
  fi
  head_before=$(git -C "$primary" rev-parse HEAD)
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  PROJ_DIR=$variant
  WT_DIR=$primary

  # The pane never leaves the primary checkout, so the settle wait runs out.
  out=$(FM_SPAWN_WORKTREE_SETTLE_POLLS=3 run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted the primary checkout under a case-variant project argument: $out"
  [ ! -e "$primary/.claude/settings.local.json" ] \
    || fail "spawn wrote harness turn-end wiring into the primary checkout"
  [ "$(git -C "$primary" rev-parse HEAD)" = "$head_before" ] \
    || fail "spawn moved the primary checkout's HEAD"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "spawn recorded a task in the primary checkout"
  pass "a case-variant project argument never makes the primary checkout look like a worktree"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_primary_checkout_behind_a_linked_project_arg_is_refused
test_case_variant_project_arg_does_not_accept_the_primary

echo "# all fm-spawn-worktree-settle tests passed"
