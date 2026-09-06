#!/usr/bin/env zsh
# tv action: switch to the workspace window and cd into the picked worktree.

source "${0:A:h}/../shared/git_workspaces.zsh"
_ws_switch_worktree "$1"
