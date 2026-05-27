#!/usr/bin/env zsh
# tv action: switch to a workspace's tmux window (creating it if missing).

source ~/src/dev_setup/shared/git_workspaces.zsh
_ws_switch_workspace "$1"
