#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the branch+code-identity matching rule that decides whether a
# no-mistakes run belongs to a given worktree, used by fm-crew-state.sh
# (read-only current-state reporting) and fm-teardown.sh (pre-teardown run
# abort, see its "Fix 1" header comment). Getting this wrong in either
# direction is unsafe: a false negative hides a genuinely parked run, and a
# false positive lets teardown act on a run it does not own.
#
# Bounded call to `no-mistakes "$@"` in dir $1, timeout $2 seconds. The bounded
# form preserves stdout, stderr, and exit status; the checked form discards
# stderr, while fm_nm_run keeps the fail-open query contract for read-only callers.
fm_nm_run_bounded() {  # <dir> <timeout_secs> <args...>
  local dir=$1 timeout_secs=$2 have_timeout=none
  shift 2
  if command -v timeout >/dev/null 2>&1; then have_timeout=timeout
  elif command -v gtimeout >/dev/null 2>&1; then have_timeout=gtimeout
  elif command -v perl >/dev/null 2>&1; then have_timeout=perl
  fi
  case "$have_timeout" in
    timeout)  ( cd "$dir" && timeout "$timeout_secs" no-mistakes "$@" ) ;;
    gtimeout) ( cd "$dir" && gtimeout "$timeout_secs" no-mistakes "$@" ) ;;
    perl)     ( cd "$dir" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout_secs" no-mistakes "$@" ) ;;
    *)        return 1 ;;
  esac
}

fm_nm_run_checked() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_bounded "$@" 2>/dev/null
}

fm_nm_run() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_checked "$@" || true
}

fm_nm_trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

fm_nm_strip_quotes() {
  local s
  s=$(fm_nm_trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  fm_nm_trim "$s"
}

# Scalar value of a TOON key in captured `axi status` output $1.
fm_nm_field() {  # <toon-output> <key>
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1
}

# 0 if run head $2 matches worktree $1's code identity, per the same rule
# everywhere this attribution is needed:
#   - missing/empty head: cannot bind; reject
#   - equal commits (short or full SHA): match
#   - worktree HEAD is an ancestor of run head: match (pipeline fix commits on
#     the same history advanced the run tip past local HEAD)
#   - run head is a strict ancestor of worktree HEAD, or diverged: no match
#     (local work advanced outside the run, or the branch tip was rewritten)
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 1
  [ "$run_full" = "$local_full" ] && return 0
  git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null
}

# --- run-object identity binding -------------------------------------------
#
# fm_nm_head_matches_worktree answers "does THIS head match" as a boolean,
# which is all a caller needs when it is about to ACT on one head:
# fm-teardown.sh's parked-run abort deliberately keeps using it, because an
# unproven identity must stay a no there. A state READER needs two things that
# boolean cannot carry.
#
# First, a run reports more than one head identity for itself. Once the
# pipeline commits a fix round it advances the run's own head past the head the
# crew submitted, and it commits those rounds in the local gate - "the pipeline
# head has moved but has not been successfully pushed" - so the advanced head
# is routinely an object the crew's worktree has never seen. no-mistakes' own
# reattach rule is that a run still matches your HEAD "either as the submitted
# head or as the current pipeline head" (its /no-mistakes skill), so both are
# identities of the same run and either one binding is a bind.
#
# Second, failing to bind has two very different meanings. A head that resolves
# here and does not match DISPROVES the run - a rewritten tip, or local work
# that advanced past it - and that is the staleness guard, which must keep
# rejecting. A head this worktree does not even have proves nothing either way.
# Collapsing both into a bare "no" is what made a healthy advancing run read as
# no current-state source at all.

# The head identities a run object reports for itself, most authoritative
# first: its current pipeline head, then the head the crew submitted. Tolerates
# the nested and the dotted `pipeline.`-prefixed renderings, and optional
# quoting. Deliberately never matches a `local.`-prefixed key: that reports the
# WORKTREE's own head, so binding on it would make every run match and silently
# delete the staleness guard.
fm_nm_run_heads() {  # <toon-output>
  local key
  for key in head submitted_head; do
    printf '%s\n' "$1" \
      | sed -n -E "s/^[[:space:]]*(pipeline\\.)?${key}:[[:space:]]*\"?([0-9a-fA-F]{4,40})\"?[[:space:]]*\$/\\2/p" \
      | head -1
  done
}

# Three-way identity verdict for ONE reported head $2 against worktree $1:
#   match       equal, or the worktree HEAD is an ancestor of it
#   mismatch    resolves here and does not match: the run is DISPROVED
#   unresolved  reported, but its object is not in this worktree: indeterminate
#   absent      nothing reported
fm_nm_head_verdict() {  # <worktree> <head>
  local wt=$1 head=$2
  [ -n "$head" ] || { printf 'absent'; return 0; }
  git -C "$wt" rev-parse --verify --quiet "${head}^{commit}" >/dev/null 2>&1 \
    || { printf 'unresolved'; return 0; }
  if fm_nm_head_matches_worktree "$wt" "$head"; then printf 'match'; else printf 'mismatch'; fi
}

# Bind a whole run object (`axi status` TOON $2) to worktree $1. Echoes
# "<verdict> <head>": match on the first reported head that binds, else the
# verdict of the run's most authoritative reported head, else a bare "absent".
# A caller may attribute the run ONLY on match; every other verdict is a reason
# it can show instead of reporting no source at all.
fm_nm_run_binding() {  # <worktree> <toon-output>
  local wt=$1 head verdict first_verdict='' first_head=''
  while IFS= read -r head; do
    [ -n "$head" ] || continue
    verdict=$(fm_nm_head_verdict "$wt" "$head")
    [ "$verdict" = match ] && { printf 'match %s' "$head"; return 0; }
    [ -n "$first_verdict" ] || { first_verdict=$verdict; first_head=$head; }
  done <<< "$(fm_nm_run_heads "$2")"
  [ -n "$first_verdict" ] || { printf 'absent'; return 0; }
  printf '%s %s' "$first_verdict" "$first_head"
}
