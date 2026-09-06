#!/usr/bin/env zsh
# List $WS_SRC_ROOT git repos (full paths) for the workspace create/add pickers.
# Excludes the workspaces dir itself. If a workspace path is given as $1, also
# excludes repos already present in that workspace.

source "${0:A:h}/../git_workspaces.zsh"

typeset -a present
ws="$1"
if [[ -n "$ws" && -d "$ws" ]]; then
  for d in "$ws"/*(/N); do present+=("${d:t}"); done
fi

for d in "$WS_SRC_ROOT"/*(/N); do
  [[ -e "$d/.git" ]] || continue            # only real git repos
  name="${d:t}"
  [[ "$name" == "${WS_ROOT:t}" ]] && continue
  (( ${present[(I)$name]} )) && continue     # already in this workspace
  print "$d"
done
