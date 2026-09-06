#!/usr/bin/env zsh
# List the repo worktrees (full paths) in the current workspace. The workspace
# comes from WS_STATE (written by `wt` or the `ws` drill action), falling back
# to $PWD.

source "${0:A:h}/../git_workspaces.zsh"

ws=$(cat "$WS_STATE" 2>/dev/null)
[[ -z "$ws" || ! -d "$ws" ]] && ws=$(_ws_from_pwd)
[[ -z "$ws" || ! -d "$ws" ]] && exit 0

for d in "$ws"/*(/N); do
  [[ -e "$d/.git" ]] && print "$d"
done
