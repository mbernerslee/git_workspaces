#!/usr/bin/env zsh
# tv action: create a new workspace from the picked repo, prompting for a branch.

source ~/src/dev_setup/shared/git_workspaces.zsh

repo="$1"
if [[ -z "$repo" ]]; then
  echo_failure "No repo given"
  exit 1
fi

read "branch?Branch for new workspace (repo: $(basename "$repo")): "
if [[ -z "$branch" ]]; then
  echo_failure "Aborted (no branch given)"
  exit 1
fi

_ws_create "$repo" "$branch"
