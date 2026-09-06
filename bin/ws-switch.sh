#!/usr/bin/env zsh
# tv action: switch to a workspace (runs the user's `switch` hook).

source "${0:A:h}/../git_workspaces.zsh"
_ws_switch_workspace "$1"
