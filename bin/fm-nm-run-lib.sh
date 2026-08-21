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
# identities of the same run and either one binding is a bind. Which keys count
# as a run's own identity is a structural question, not a spelling one - see
# fm_nm_run_heads.
#
# Second, failing to bind has two very different meanings. A head that resolves
# here and does not match DISPROVES the run - a rewritten tip, or local work
# that advanced past it - and that is the staleness guard, which must keep
# rejecting. A head this worktree does not even have proves nothing either way.
# Collapsing both into a bare "no" is what made a healthy advancing run read as
# no current-state source at all.

# The head identities a run reports for itself, most authoritative first: the
# run object's own heads, then its pipeline block's.
#
# Block-aware on purpose. `axi status` also reports the WORKTREE's own head, as
# an indented bare `head:` inside branch_sync's `local:` block (verified against
# no-mistakes v1.48.0, whose branch_sync renders `local:` with `branch`, `head`,
# `clean` and `pipeline:` with `submitted_head`, `current_head`, `pushed_head`).
# A flat "first key that looks like a head" match can therefore read the
# worktree's own head as the run's identity, which would make every run on the
# branch bind and silently delete the staleness guard. Excluding it by key
# SPELLING does not hold: an indented `head:` under `local:` and a flattened
# `local.head:` are one field rendered two ways, and the next field added inside
# `local:` would reopen the hole. So the boundary is the enclosing BLOCK - only
# the `run:` object and the `pipeline:` block supply run identities, and nothing
# under `local:` can, whatever it is called or added later.
#
# Within those blocks any `head`/`*_head` key counts, so a head field the vendor
# adds to the pipeline block keeps working; an unrecognized one merely goes
# unconsulted, which refuses loudly rather than binding wrongly. Both renderings
# are accepted: nested blocks, and keys flattened with a dotted prefix
# (`pipeline.submitted_head:`), the spelling in the originally reported evidence.
fm_nm_run_heads() {  # <toon-output>
  printf '%s\n' "$1" | awk '
    function block_path(   i, p) {
      p = ""
      for (i = 1; i <= top; i++) p = (p == "" ? sname[i] : p "." sname[i])
      return p
    }
    {
      match($0, /^[ \t]*/); ind = RLENGTH
      rest = substr($0, ind + 1)
      # Only `key:` and `key: value` lines carry structure. TOON table headers
      # (`steps[9]{...}:`), their rows, and blank lines are skipped without
      # disturbing the block stack.
      if (match(rest, /^[A-Za-z_][A-Za-z0-9_.]*:/) == 0) next
      key = substr(rest, 1, RLENGTH - 1)
      val = substr(rest, RLENGTH + 1)
      sub(/^[ \t]+/, "", val); sub(/[ \t]+$/, "", val)
      while (top > 0 && sind[top] >= ind) top--
      if (val == "") { top++; sind[top] = ind; sname[top] = key; next }
      leaf = key; prefix = ""
      if (index(key, ".") > 0) {
        n = split(key, part, ".")
        leaf = part[n]
        for (i = 1; i < n; i++) prefix = (prefix == "" ? part[i] : prefix "." part[i])
      }
      path = block_path()
      if (prefix != "") path = (path == "" ? prefix : path "." prefix)
      if (leaf != "head" && leaf !~ /_head$/) next
      if (path != "run" && path != "pipeline" && path != "branch_sync.pipeline") next
      gsub(/^"|"$/, "", val)
      if (val !~ /^[0-9a-fA-F]{4,40}$/) next
      if (seen[val]++) next
      if (path == "run") run_head[++nrun] = val; else pipe_head[++npipe] = val
    }
    END {
      for (i = 1; i <= nrun; i++) print run_head[i]
      for (i = 1; i <= npipe; i++) print pipe_head[i]
    }
  '
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
# STRONGEST verdict any reported head produced, paired with that head, else a
# bare "absent". A caller may attribute the run ONLY on match; every other
# verdict is a reason it can show instead of reporting no source at all.
#
# Binding order is unchanged - the first head that matches still wins - but the
# non-binding verdict reported is the strongest, not the first: a proven
# `mismatch` outranks an indeterminate `unresolved`, which outranks `absent`.
# Reporting the first one lets an unresolvable run head hide a submitted head
# that RESOLVES here and disproves the run, and the reason then reads "unpushed
# pipeline commits?" - a healthy advancing run - when local work has in fact
# advanced past the run. A reason is only worth having if it is accurate when a
# supervisor reads it, so report the head whose verdict is actually proved.
fm_nm_run_binding() {  # <worktree> <toon-output>
  local wt=$1 head verdict rank best_rank=0 best_verdict='' best_head=''
  while IFS= read -r head; do
    [ -n "$head" ] || continue
    verdict=$(fm_nm_head_verdict "$wt" "$head")
    [ "$verdict" = match ] && { printf 'match %s' "$head"; return 0; }
    case "$verdict" in
      mismatch)   rank=3 ;;
      unresolved) rank=2 ;;
      *)          rank=1 ;;
    esac
    if [ "$rank" -gt "$best_rank" ]; then
      best_rank=$rank; best_verdict=$verdict; best_head=$head
    fi
  done <<< "$(fm_nm_run_heads "$2")"
  [ -n "$best_verdict" ] || { printf 'absent'; return 0; }
  printf '%s %s' "$best_verdict" "$best_head"
}
