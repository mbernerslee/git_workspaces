#!/usr/bin/env zsh
# ws-repos — discover and manage the repos in the CURRENT workspace.
#
# Built so an agent (Claude) running inside a workspace can tell which repos are
# already worktree'd here vs. which main clones under $WS_SRC_ROOT it could pull in, and
# add them — without the interactive `wsa` (no tmux/cd side effects). Reuses the
# workspace internals in git_workspaces.zsh, so it stays project-agnostic.
#
#   ws-repos.sh [list]          # show in-workspace repos + what's addable from $WS_SRC_ROOT
#   ws-repos.sh add <repo>...   # worktree main clone(s) into this workspace (this branch)
#
# Must be run from inside a workspace (a dir under $WS_ROOT/<name>/...).
set -u
source "${0:A:h}/../shared/git_workspaces.zsh"

workspace="$(_ws_from_pwd)" || true
if [[ -z "${workspace:-}" ]]; then
  echo_failure "Not inside a workspace — cd into one under $WS_ROOT first."
  exit 1
fi
short="${workspace:t}"
branch="$(_ws_branch "$workspace" 2>/dev/null)"

# Repos currently in the workspace (subdirs that are git worktrees).
typeset -a in_ws
for d in "$workspace"/*(/N); do
  [[ -e "$d/.git" ]] && in_ws+=("${d:t}")
done

cmd="${1:-list}"
case "$cmd" in
  list|ls)
    print -r -- "Workspace: $short${branch:+  (branch: $branch)}"
    print -r -- "  dir: $workspace"
    print -r --
    print -r -- "In this workspace (USE THESE — never ~/src/<repo>):"
    if (( ${#in_ws} )); then
      for r in "${in_ws[@]}"; do print -r -- "  - $r"; done
    else
      print -r -- "  (none)"
    fi
    print -r --
    print -r -- "Available to add from $WS_SRC_ROOT:"
    local found=0 name
    for d in "$WS_SRC_ROOT"/*(/N); do
      name="${d:t}"
      [[ "$name" == "${WS_ROOT:t}" ]] && continue   # skip the workspaces dir itself
      [[ -e "$d/.git" ]] || continue                # only real git repos
      (( ${in_ws[(I)$name]} )) && continue          # already in this workspace
      print -r -- "  - $name"
      found=1
    done
    (( found )) || print -r -- "  (none)"
    print -r --
    print -r -- "To pull one in:  $0 add <repo> [repo...]"
    ;;
  add)
    shift
    (( $# )) || { echo_failure "Usage: $0 add <repo> [repo...]"; exit 1; }
    _ws_add "$workspace" "$@"
    ;;
  *)
    echo_failure "Unknown command: '$cmd' (use 'list' or 'add <repo>')."
    exit 1
    ;;
esac
