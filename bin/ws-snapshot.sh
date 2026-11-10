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
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
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
    failed=0
    for r in "${repos[@]}"; do
      _ws_snapshot "$r" $force || failed=1
    done
    exit $failed
    ;;
esac
