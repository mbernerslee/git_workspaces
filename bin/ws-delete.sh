#!/usr/bin/env zsh
# tv action: delete a workspace — remove every worktree and the dir, then run
# the user's `deleted` hook (branches are kept in git).

source "${0:A:h}/../git_workspaces.zsh"
_ws_delete "$1"
