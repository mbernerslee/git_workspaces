#!/usr/bin/env zsh
# tv action: add the picked repo as a worktree to the current workspace (from
# WS_STATE, falling back to $PWD).

source "${0:A:h}/../git_workspaces.zsh"

if [[ -z "$1" ]]; then
  echo_failure "No repo given"
  exit 1
fi

ws=$(cat "$WS_STATE" 2>/dev/null)
[[ -z "$ws" || ! -d "$ws" ]] && ws=$(_ws_from_pwd)
if [[ -z "$ws" ]]; then
  echo_failure "No current workspace"
  exit 1
fi

_ws_add "$ws" "$1"
