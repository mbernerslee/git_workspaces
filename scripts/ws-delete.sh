#!/usr/bin/env zsh
# tv action: delete a workspace — remove every worktree, the dir, and the tmux
# window (branches are kept in git).

source "${0:A:h}/../shared/git_workspaces.zsh"
_ws_delete "$1"
