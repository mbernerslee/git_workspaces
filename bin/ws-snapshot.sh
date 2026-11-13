#!/usr/bin/env zsh
# ws-snapshot — make and inspect build snapshots (see "Snapshots" in
# git_workspaces.zsh). New workspaces start from a repo's latest snapshot, so
# they open already compiled.
#
#   ws-snapshot.sh <repo>... [--force]   bring these repos' snapshots up to date
#   ws-snapshot.sh --all [--force]       …every repo under $WS_SRC_ROOT whose
#                                        .ws-init defines a build phase (ws_build)
#   ws-snapshot.sh status [repo...]      what's there, how fresh, whether in use
#   ws-snapshot.sh rm <repo>...          delete a repo's snapshots + checkout
#
# Meant to run on a schedule (every ~10 min): a run where origin hasn't moved
# is just a `git fetch`. Exit status is non-zero if any build failed.
# Several repos are snapshotted in parallel (each has its own lock); each one's
# output is printed as a block when it finishes, in the order given.
set -u
source "${0:A:h}/../git_workspaces.zsh"

opted_in_repos() {
  local d
  for d in "$WS_SRC_ROOT"/*(/N); do
    [[ -e "$d/.git" ]] && _ws_snapshot_opted_in "$d" && print -r -- "$d"
  done
}

cmd="${1:-}"
case "$cmd" in
  ""|-h|--help)
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  status)
    shift
    typeset -a repos
    if (( $# )); then
      for r in "$@"; do repos+=("$(_ws_resolve_main_clone "$r")"); done
    else
      repos=(${(f)"$(opted_in_repos)"})
    fi
    (( ${#repos} )) || { echo "No repos opted in (no .ws-init defines ws_build)."; exit 0; }
    for r in "${repos[@]}"; do _ws_snapshot_status "$r"; done
    ;;
  rm)
    shift
    (( $# )) || { echo_failure "Usage: ws-snapshot.sh rm <repo>..."; exit 1; }
    for r in "$@"; do
      main_clone="$(_ws_resolve_main_clone "$r")"
      sdir="$(_ws_snapshot_dir "$main_clone")"
      if [[ -d "$sdir/lock" ]]; then
        echo_failure "${main_clone:t}: a snapshot is being made — try again later"; continue
      fi
      [[ -e "$sdir/checkout/.git" ]] && git -C "$main_clone" worktree remove --force "$sdir/checkout"
      rm -rf "$sdir" && echo_success "${main_clone:t}: snapshots removed"
    done
    ;;
  *)
    force=""
    typeset -a repos
    for arg in "$@"; do
      case "$arg" in
        --force) force="--force" ;;
        --all) repos+=(${(f)"$(opted_in_repos)"}) ;;
        -*) echo_failure "Unknown option: $arg"; exit 1 ;;
        *) repos+=("$arg") ;;
      esac
    done
    (( ${#repos} )) || { echo "Nothing to snapshot."; exit 0; }
    if (( ${#repos} == 1 )); then
      _ws_snapshot "${repos[1]}" $force; exit $?
    fi
    # One background job per repo, output buffered so blocks don't interleave;
    # printed in order (a later repo that finished first waits its turn).
    out_dir=$(mktemp -d "${TMPDIR:-/tmp}/ws-snapshot.XXXXXX")
    trap 'kill ${pids[@]} 2>/dev/null; rm -rf "$out_dir"' EXIT
    trap 'exit 130' INT TERM HUP
    typeset -a pids
    for i in {1..${#repos}}; do
      _ws_snapshot "${repos[i]}" $force >"$out_dir/$i" 2>&1 &
      pids+=($!)
    done
    failed=0
    for i in {1..${#repos}}; do
      wait "${pids[i]}" || failed=1
      cat "$out_dir/$i"
    done
    pids=()
    exit $failed
    ;;
esac
