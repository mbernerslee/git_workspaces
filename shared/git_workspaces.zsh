# Workspaces (multi-repo git worktrees) + Tmux
#
# A "workspace" groups per-repo worktrees you work on together under
#   ~/src/workspaces/<short>/<repo>/
# The workspace IS a branch: every repo in it uses the same branch name.
# Main clones live at ~/src/<repo> and are never touched. There is one tmux
# window per workspace (in the mob-editor/mob-shell pair), rooted at the
# workspace; switching a worktree just cd's that window's pane into the repo.
#
# Commands:
#   wsc [--bg] <branch>   create a workspace from the current repo (--bg: don't
#                         switch to the new tmux windows)
#   wsa <repo> [repo...]  add repos to the workspace you're standing in
#   wsd [name|path]       delete a workspace (worktrees + dir; branches kept)
#   wsp [--yes] [--force] purge every workspace with no open tmux window
#                         (--force includes ones with uncommitted changes)
#   ws                    TV: workspaces — enter=switch, ctrl-g=drill into repos,
#                         ctrl-n=new, ctrl-d=delete
#   wt                    TV: worktrees in the current workspace — enter=switch,
#                         ctrl-n=add
#
# (ctrl-g avoids the built-in ctrl-l=toggle_layout that shadowed the drill key.)
#
# Sourced from shared/zshrc (where the real echo_*/master_branch live) AND
# directly by the tv helper scripts in scripts/w{s,t}-*.sh — so the helpers
# below are defined only as fallbacks when sourced standalone.

WS_ROOT="$HOME/src/workspaces"
WS_STATE=/tmp/tv-ws          # tv hands the "current workspace" to the wt channel here
_WS_TPC=~/src/dev_setup/scripts/tmux-pair-cmd.sh

# Catppuccin colours matching zshrc's INFO=$TEAL / SUCCESS=$GREEN / FAILURE=$RED.
(( $+functions[echo_info] ))    || echo_info()    { print -P "%F{#8bd5ca}$*%f"; }
(( $+functions[echo_success] )) || echo_success() { print -P "%F{#a6da95}$*%f"; }
(( $+functions[echo_failure] )) || echo_failure() { print -P "%F{#ed8796}$*%f" >&2; }
# Peach, for warnings that aren't outright failures.
(( $+functions[echo_warn] ))    || echo_warn()    { print -P "%F{#f5a97f}$*%f" >&2; }

# Ask a yes/no question on the tty; return 0 only on an explicit yes. Defaults
# to no — so a non-interactive caller (no tty) safely aborts.
_ws_confirm() {
  local reply
  read "reply?$1 [y/N] "
  [[ "$reply" == [yY]* ]]
}
(( $+functions[master_branch] )) || master_branch() {
  git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'
}

# Copy preserving mtimes (the warm-_build trick depends on them) with COW where
# the fs has it: APFS clonefile on macOS; GNU cp elsewhere (--reflink=auto uses
# COW on btrfs/xfs and silently falls back to a plain copy on ext4).
_ws_copy() {
  if [[ "$OSTYPE" == darwin* ]]; then
    cp -Rc "$1" "$2"
  else
    cp -a --reflink=auto "$1" "$2"
  fi
}

# Resolve a repo argument (bare name under ~/src, or a path) to a main-clone path.
_ws_resolve_main_clone() {
  local arg="$1"
  if [[ "$arg" == */* || "$arg" == "~"* ]]; then
    echo "${arg/#\~/$HOME}"
  else
    echo "$HOME/src/$arg"
  fi
}

# Echo the workspace dir that the current directory lives in (empty if none).
_ws_from_pwd() {
  local cwd=$(pwd -P)
  local root=$(cd "$WS_ROOT" 2>/dev/null && pwd -P)
  [[ -z "$root" || "$cwd" != "$root"/* ]] && return 1
  local rest="${cwd#$root/}"
  echo "$root/${rest%%/*}"
}

# Recover a workspace's branch from one of its existing member repos.
_ws_branch() {
  local workspace="$1" member branch
  for member in "$workspace"/*(/N); do
    [[ -e "$member/.git" ]] || continue
    branch=$(git -C "$member" branch --show-current 2>/dev/null)
    [[ -n "$branch" ]] && { echo "$branch"; return 0; }
  done
  return 1
}

_ws_short_name() {
  local branch="${1//\//-}"  # slashes would nest the workspace dir under WS_ROOT
  local max=25
  # Strip plo-XXXX- prefix (Linear ticket IDs)
  local stripped=$(echo "$branch" | sed 's/^plo-[0-9]*-//')
  # Keep as many dash-separated segments as fit within max chars
  local result="" seg
  while IFS='-' read -rA segs; do
    for seg in "${segs[@]}"; do
      if [[ -z "$result" ]]; then
        result="$seg"
      elif (( ${#result} + 1 + ${#seg} <= max )); then
        result="${result}-${seg}"
      else
        break 2
      fi
    done
  done <<< "$stripped"
  echo "$result"
}

# Add a worktree for one repo into a workspace.
#   _ws_setup_worktree <main_clone> <branch> <dest>
# Resolves the branch (remote / local / new-from-master), copies build
# artifacts, restores tracked-file mtimes, symlinks env files. (Mix-manifest
# cwd rewriting was retired — ploy-server sets elixirc_options: [check_cwd: false].)
_ws_setup_worktree() {
  local main_clone="$1" branch="$2" dest="$3"

  if [[ -d "$dest" ]]; then
    echo_failure "Worktree directory already exists: $dest"
    return 1
  fi

  # Per-repo workspace hook. A single executable .ws-init in the main clone
  # (typically git-excluded / private, so it applies to every worktree without
  # being committed) is invoked with the phase as $1:
  #   pre    — BEFORE the worktree is created (cwd = main clone; dest not made)
  #   post   — AFTER it is fully set up       (cwd = the new worktree == WS_DEST)
  #   switch — when switching TO the workspace (ws picker; cwd = the worktree).
  #            Print a directory to stdout to make the tmux panes land there
  #            instead of the workspace root. See _ws_switch_dir.
  #   delete — BEFORE the worktree is removed (cwd = the worktree, which still
  #            exists). Undo per-worktree resources `post` created OUTSIDE the
  #            workspace dir (cloned DBs, …). Failure warns but never blocks
  #            deletion. See _ws_delete.
  # The hook defines shell functions `ws_pre` / `ws_post` / `ws_switch` /
  # `ws_delete` and dispatches on the phase, defining only the phase(s) it
  # cares about. All phases get the same context via env: WS_DEST / WS_BRANCH /
  # WS_MAIN_CLONE. A non-zero `pre` ABORTS creation — it is a precondition.
  if [[ -x "$main_clone/.ws-init" ]]; then
    echo_info "Running .ws-init pre from $(basename "$main_clone")..."
    if ! ( cd "$main_clone" && WS_DEST="$dest" WS_BRANCH="$branch" WS_MAIN_CLONE="$main_clone" \
             "$main_clone/.ws-init" pre ); then
      echo_failure ".ws-init pre failed — aborting worktree creation for $(basename "$main_clone")"
      return 1
    fi
  fi

  local main_branch=$(git -C "$main_clone" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
  if [[ -z "$main_branch" ]]; then
    # No origin/HEAD recorded locally — guess from the usual suspects.
    local b
    for b in main master; do
      if git -C "$main_clone" show-ref --verify --quiet "refs/heads/$b"; then
        main_branch="$b"
        break
      fi
    done
  fi
  [[ -z "$main_branch" ]] && main_branch="main"

  echo_info "Fetching origin in $(basename "$main_clone")..."
  git -C "$main_clone" fetch origin || { echo_failure "Failed to fetch origin"; return 1; }

  # New branches are based on the LOCAL default branch; whether that branch is
  # synced first is the per-repo .ws-init `pre` hook's decision (ploy's runs
  # `git pull`, so team repos still effectively base on origin). Divergence is
  # warned about so a stale or unpushed base is a visible choice, not a silent
  # surprise. Repos with no local copy of the default branch fall back to
  # origin's.
  local base_ref="origin/$main_branch"
  if git -C "$main_clone" show-ref --verify --quiet "refs/heads/$main_branch"; then
    base_ref="$main_branch"
    if git -C "$main_clone" show-ref --verify --quiet "refs/remotes/origin/$main_branch"; then
      local behind=$(git -C "$main_clone" rev-list --count "$main_branch..origin/$main_branch" 2>/dev/null)
      local ahead=$(git -C "$main_clone" rev-list --count "origin/$main_branch..$main_branch" 2>/dev/null)
      (( behind > 0 )) && echo_warn "⚠ Local $main_branch is $behind commit(s) behind origin/$main_branch — basing the workspace on the stale local branch anyway"
      (( ahead > 0 )) && echo_info "Local $main_branch has $ahead unpushed commit(s); the workspace will include them"
    fi
  fi

  echo_info "Creating worktree at $dest..."
  local remote_exists=false local_exists=false
  git -C "$main_clone" show-ref --verify --quiet "refs/remotes/origin/$branch" 2>/dev/null && remote_exists=true
  git -C "$main_clone" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null && local_exists=true

  # A new workspace branch should not already exist anywhere. If it does, this
  # is unexpected — warn and require explicit confirmation before reusing it.
  if [[ "$remote_exists" == true || "$local_exists" == true ]]; then
    local where=""
    [[ "$local_exists" == true ]] && where="locally"
    [[ "$remote_exists" == true ]] && where="${where:+$where and }on origin"
    echo_warn "⚠ Branch '$branch' already exists ($where) in $(basename "$main_clone")."
    echo_warn "  A new workspace branch should not already exist."
    if ! _ws_confirm "  Use the existing branch anyway?"; then
      echo_failure "Aborted — branch '$branch' left untouched."
      return 1
    fi
  fi

  if [[ "$remote_exists" == true ]]; then
    echo_info "Checking out existing remote branch '$branch'..."
    git -C "$main_clone" worktree add "$dest" "$branch" || { echo_failure "Failed to create worktree"; return 1; }
  elif [[ "$local_exists" == true ]]; then
    echo_info "Using existing local branch '$branch'..."
    git -C "$main_clone" worktree add "$dest" "$branch" || { echo_failure "Failed to create worktree"; return 1; }
  else
    echo_info "Creating new branch '$branch' from $base_ref..."
    git -C "$main_clone" worktree add "$dest" -b "$branch" "$base_ref" || { echo_failure "Failed to create worktree"; return 1; }
  fi

  # Copy build artifacts if they exist.
  # deps/ must be copied BEFORE _build/, because _build/<env>/lib/<dep>/{src,include,priv}
  # are relative symlinks into deps/. If deps/ isn't there yet, the touch step below
  # follows the dangling symlinks and fails to create files at non-existent targets.
  if [[ -d "$main_clone/deps" ]]; then
    echo_info "Copying deps/..."
    _ws_copy "$main_clone/deps" "$dest/deps"
  fi
  if [[ -d "$main_clone/_build" ]]; then
    echo_info "Copying _build/..."
    _ws_copy "$main_clone/_build" "$dest/_build"
  fi
  # JS deps (e.g. ploy-client): node_modules is gitignored so the worktree has
  # none — without it `npm run dev` can't find local bins like vite. Clone-copy
  # it (APFS COW, keeps the relative .bin symlinks intact).
  if [[ -d "$main_clone/node_modules" ]]; then
    echo_info "Copying node_modules/..."
    _ws_copy "$main_clone/node_modules" "$dest/node_modules"
  fi
  # git worktree add stamps EVERY checked-out file with the current time, which
  # breaks Elixir's incremental build. On `mix compile`, Mix compares the mtime
  # of mix.exs and config/*.exs against what the copied manifest recorded; if
  # any are newer it concludes "config changed" and forces a FULL recompile —
  # the digest fallback that protects ordinary source files does NOT apply to
  # this config-staleness check, so the relocated _build is thrown away. Restore
  # each tracked file's mtime from the main clone (same commit = same content),
  # so the worktree looks mtime-identical to the state the manifest was built
  # against. -z makes this robust to spaces/newlines in paths. (Repo-agnostic:
  # copying mtimes from an identical checkout is always safe.)
  echo_info "Restoring file mtimes from $(basename "$main_clone")..."
  git -C "$dest" ls-files -z | while IFS= read -r -d '' f; do
    [[ -e "$main_clone/$f" && -e "$dest/$f" ]] && touch -r "$main_clone/$f" "$dest/$f"
  done

  # NOTE: do NOT bump _build/deps mtimes to "now". _ws_copy already
  # preserves the main clone's mtimes, which is exactly what the manifest
  # expects. Touching _build forward re-breaks the build: Mix.Project's config
  # set includes _build/<env>/lib/<app>/.mix/compile.lock, so a freshly-touched
  # compile.lock looks newer than the manifest → "config changed" → full
  # recompile. (This is a verified footgun, not a hypothetical: a prior
  # `find _build -exec touch` step here caused exactly that.) Elixir never
  # compares artifact-vs-source file mtimes directly — it uses the manifest's
  # own recorded mtimes plus per-source content digests — so there is nothing
  # to gain by making artifacts "newer", only this regression to cause.

  # DISABLED 2026-07-20: manifest cwd rewriting is obsolete for ploy-server.
  # Mix bakes the absolute project path into _build/**/.mix/compile.elixir and
  # a mismatch vs File.cwd!() used to force a FULL recompile, so this block
  # rewrote the old root prefix to the new one in every manifest term. Since
  # ploy-server PR #2735 set `elixirc_options: [check_cwd: false]` in mix.exs
  # (Elixir >= 1.19.2 feature), Mix skips that cwd check entirely and the
  # copied _build is reused as-is — verified: a relocated clone compiles 0
  # files without this rewrite. Kept commented out in case a future Elixir
  # repo WITHOUT check_cwd: false needs warm relocation; prefer adding the
  # mix.exs option to that repo instead of re-enabling this.
  # NOTE: the "Restoring file mtimes" step above is NOT obsolete — the
  # config-staleness check (mix.exs / config/*.exs mtimes vs manifest) still
  # fires independently of check_cwd; verified: touching them to "now" forces
  # a ~3.3k-file recompile even with the flag on.
  # if [[ -d "$dest/_build" ]] && command -v elixir >/dev/null 2>&1; then
  #   echo_info "Rewriting Mix build manifests for new path..."
  #   GWTC_OLD_ROOT="$main_clone" GWTC_NEW_ROOT="$dest" elixir -e '
# defmodule GwtcFix do
#   def walk(t, o, n) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.map(&walk(&1, o, n)) |> List.to_tuple()
#   def walk(l, o, n) when is_list(l), do: Enum.map(l, &walk(&1, o, n))
#   def walk(m, o, n) when is_map(m), do: :maps.map(fn _k, v -> walk(v, o, n) end, m)
#   def walk(b, o, n) when is_binary(b) do
#     cond do
#       not String.valid?(b) -> b
#       b == o -> n
#       String.starts_with?(b, o <> "/") -> n <> binary_part(b, byte_size(o), byte_size(b) - byte_size(o))
#       true -> b
#     end
#   end
#   def walk(x, _, _), do: x
# end
#
# old = System.fetch_env!("GWTC_OLD_ROOT")
# new = System.fetch_env!("GWTC_NEW_ROOT")
#
# Path.join(new, "_build/**/.mix/compile.elixir")
# |> Path.wildcard(match_dot: true)
# |> Enum.each(fn path ->
#   try do
#     term = path |> File.read!() |> :erlang.binary_to_term()
#     rewritten = GwtcFix.walk(term, old, new)
#     if rewritten != term, do: File.write!(path, :erlang.term_to_binary(rewritten, [:compressed]))
#   rescue
#     _ -> :ok
#   end
# end)
# ' && echo_success "Mix manifests rewritten" || echo_failure "Manifest rewrite failed (a recompile may be needed)"
  # fi

  # Symlink env files if they exist in the main clone — but NEVER over a file
  # the worktree already has (a TRACKED .env/.mcp.json/… was checked out by
  # `worktree add`; ln -sf over it would leave the worktree permanently dirty
  # with a typechange).
  if [[ -e "$main_clone/.env" && ! -e "$dest/.env" ]]; then
    ln -sf "$main_clone/.env" "$dest/.env"
    echo_success "Symlinked .env"
  fi
  if [[ -e "$dest/.envrc" ]]; then
    # The repo tracks its own .envrc (e.g. one that self-derives per-worktree
    # isolation) — nothing to symlink, just authorise it for direnv.
    direnv allow "$dest" 2>/dev/null || true
    echo_success "Authorised tracked .envrc"
  # Skip the .envrc symlink when the repo has a .ws-init hook — that hook
  # generates its own per-worktree .envrc, so there's nothing to symlink (and
  # writing over a symlink would clobber the main clone's file).
  elif [[ -f "$main_clone/.envrc" && ! -x "$main_clone/.ws-init" ]]; then
    ln -sf "$main_clone/.envrc" "$dest/.envrc"
    echo_success "Symlinked .envrc"
    direnv allow "$dest"
  fi
  if [[ -f "$main_clone/.mcp.json" && ! -e "$dest/.mcp.json" ]]; then
    ln -sf "$main_clone/.mcp.json" "$dest/.mcp.json"
    echo_success "Symlinked .mcp.json"
  fi
  if [[ -f "$main_clone/.claude/settings.local.json" && ! -e "$dest/.claude/settings.local.json" ]]; then
    mkdir -p "$dest/.claude"
    ln -sf "$main_clone/.claude/settings.local.json" "$dest/.claude/settings.local.json"
    echo_success "Symlinked .claude/settings.local.json"
  fi
  if [[ -f "$main_clone/CLAUDE.local.md" && ! -e "$dest/CLAUDE.local.md" ]]; then
    ln -sf "$main_clone/CLAUDE.local.md" "$dest/CLAUDE.local.md"
    echo_success "Symlinked CLAUDE.local.md"
  fi

  # The `post` phase of the same .ws-init hook (see the `pre` invocation above).
  # Runs with the fully set-up worktree as cwd, so a repo can wire up its
  # per-workspace state (ports, DB, env, …) without the workspace layer knowing
  # anything project-specific. cwd == WS_DEST here.
  if [[ -x "$main_clone/.ws-init" ]]; then
    echo_info "Running .ws-init post from $(basename "$main_clone")..."
    ( cd "$dest" && WS_DEST="$dest" WS_BRANCH="$branch" WS_MAIN_CLONE="$main_clone" \
        "$main_clone/.ws-init" post )
  fi
}

# _ws_create <repo|path> <branch> [--bg|--no-window] — create a workspace from
# a repo + branch. Repo-agnostic (the branch is based off origin's default by
# _ws_setup_worktree, so the clone needn't be on master). Opens and selects the
# workspace window; with --bg the window is created in the background and not
# selected; with --no-window no tmux window is made at all (for headless
# scratch workspaces no human will ever type into — an idle window on one just
# looks like abandoned work).
_ws_create() {
  if [[ -z "$1" || -z "$2" ]]; then
    echo_failure "Usage: _ws_create <repo|path> <branch> [--bg|--no-window]"
    return 1
  fi
  local main_clone=$(_ws_resolve_main_clone "$1")
  local branch="$2"
  local bg="" no_window="" arg
  for arg in "${@:3}"; do
    case "$arg" in
      --bg) bg=1 ;;
      --no-window) no_window=1 ;;
    esac
  done
  if [[ ! -e "$main_clone/.git" ]]; then
    echo_failure "No git repo at $main_clone"
    return 1
  fi

  local repo=$(basename "$main_clone")
  local short=$(_ws_short_name "$branch")
  local workspace="$WS_ROOT/$short"

  # A leftover empty dir (e.g. from a previously aborted create) shouldn't block
  # us — only refuse if the workspace actually has contents.
  if [[ -d "$workspace" && -n "$(ls -A "$workspace" 2>/dev/null)" ]]; then
    echo_failure "Workspace already exists (and is not empty): $workspace"
    return 1
  fi
  if [[ -z "$no_window" ]] && tmux list-windows -t mob-editor -F '#{window_name}' 2>/dev/null | grep -qx "$short"; then
    echo_failure "Tmux window '$short' already exists in mob-editor"
    return 1
  fi

  mkdir -p "$workspace"
  # rmdir only removes it if still empty, so an aborted setup leaves no stub.
  _ws_setup_worktree "$main_clone" "$branch" "$workspace/$repo" || { rmdir "$workspace" 2>/dev/null; return 1; }

  # Open the workspace window with its pane already in the repo we just made.
  # With --bg, create it without switching to it; --no-window skips it.
  if [[ -n "$no_window" ]]; then
    :
  elif [[ -n "$bg" ]]; then
    "$_WS_TPC" goto mob-editor "$short" "$workspace/$repo" --bg
  else
    "$_WS_TPC" goto mob-editor "$short" "$workspace/$repo"
    "$_WS_TPC" select mob-editor "$short"
  fi

  echo_success "Workspace ready: $workspace"
  echo_success "Added '$repo' on branch '$branch'"
  if [[ -z "$no_window" ]]; then
    echo_success "Tmux window '$short' created${bg:+ (in background)}"
  fi
  return 0
}

# _ws_add <workspace> <repo|path> [repo...] — add repos to a workspace, all on
# the workspace's branch. Sets _WS_LAST_ADDED to the dir of the last repo added
# (a global, not stdout, so progress output and prompts reach the terminal).
_ws_add() {
  _WS_LAST_ADDED=""
  local workspace="$1"; shift
  if [[ -z "$workspace" || -z "$1" ]]; then
    echo_failure "Usage: _ws_add <workspace> <repo> [repo...]"
    return 1
  fi

  local branch=$(_ws_branch "$workspace")
  if [[ -z "$branch" ]]; then
    echo_failure "Could not determine workspace branch from repos in $workspace"
    return 1
  fi

  local arg main_clone repo
  for arg in "$@"; do
    main_clone=$(_ws_resolve_main_clone "$arg")
    repo=$(basename "$main_clone")

    if [[ ! -e "$main_clone/.git" ]]; then
      echo_failure "No git repo at $main_clone — skipping '$arg'"
      continue
    fi
    if [[ -d "$workspace/$repo" ]]; then
      echo_failure "Repo '$repo' already in workspace — skipping"
      continue
    fi
    echo_info "Adding '$repo' on branch '$branch'..."
    if _ws_setup_worktree "$main_clone" "$branch" "$workspace/$repo"; then
      echo_success "Added '$repo'"
      _WS_LAST_ADDED="$workspace/$repo"
    else
      echo_failure "Failed to add '$repo'"
    fi
  done
}

# Ask a workspace's member repos where a switch should land. Each member's
# main-clone .ws-init may define a `switch` phase (see _ws_setup_worktree for
# the hook convention) that prints a directory to stdout; the first member to
# print an existing directory wins. Falls back to the workspace dir itself.
_ws_switch_dir() {
  local workspace="$1" branch member main_clone dir
  branch=$(_ws_branch "$workspace")
  for member in "$workspace"/*(/N); do
    [[ -e "$member/.git" ]] || continue
    main_clone=$(git -C "$member" worktree list 2>/dev/null | head -1 | awk '{print $1}')
    [[ -n "$main_clone" && -x "$main_clone/.ws-init" ]] || continue
    dir=$( cd "$member" && WS_DEST="$member" WS_BRANCH="$branch" WS_MAIN_CLONE="$main_clone" \
             "$main_clone/.ws-init" switch 2>/dev/null )
    [[ -n "$dir" && -d "$dir" ]] && { echo "$dir"; return 0; }
  done
  echo "$workspace"
}

# _ws_switch_workspace <workspace-dir> — select its window (creating if
# missing), landing the panes wherever the members' `switch` hooks point
# (workspace root if none do).
_ws_switch_workspace() {
  local workspace="$1"
  [[ -z "$workspace" ]] && { echo_failure "Usage: _ws_switch_workspace <dir>"; return 1; }
  local short=$(basename "$workspace")
  "$_WS_TPC" goto mob-editor "$short" "$(_ws_switch_dir "$workspace")"
  "$_WS_TPC" select mob-editor "$short"
}

# _ws_switch_worktree <repo-dir> — switch to the workspace window (creating if
# missing) and cd both panes into the chosen repo's worktree.
_ws_switch_worktree() {
  local repodir="$1"
  [[ -z "$repodir" ]] && { echo_failure "Usage: _ws_switch_worktree <repo-dir>"; return 1; }
  local workspace=$(dirname "$repodir")
  local short=$(basename "$workspace")
  "$_WS_TPC" goto mob-editor "$short" "$repodir"
  "$_WS_TPC" select mob-editor "$short"
}

# _ws_delete <workspace-dir> — run each member repo's .ws-init `delete` hook,
# remove every member worktree (the branches stay in git), then rm the
# workspace dir and kill its tmux window.
_ws_delete() {
  local workspace="$1"
  [[ -z "$workspace" ]] && { echo_failure "Usage: _ws_delete <workspace-dir>"; return 1; }

  # Safety: only ever operate under WS_ROOT.
  case "$workspace" in
    "$WS_ROOT"/*) ;;
    *) echo_failure "Refusing: '$workspace' is not under $WS_ROOT"; return 1 ;;
  esac
  if [[ ! -d "$workspace" ]]; then
    echo_failure "No such workspace: $workspace"
    return 1
  fi

  local short=$(basename "$workspace")
  local member main_worktree member_branch

  for member in "$workspace"/*(/N); do
    [[ -e "$member/.git" ]] || continue
    main_worktree=$(git -C "$member" worktree list 2>/dev/null | head -1 | awk '{print $1}')
    [[ -z "$main_worktree" || "$main_worktree" == "$member" ]] && continue

    # Teardown hook: the `delete` phase of the main clone's .ws-init (see
    # _ws_setup_worktree). A failed hook must never leave the workspace
    # half-deleted, so warn and carry on.
    if [[ -x "$main_worktree/.ws-init" ]]; then
      member_branch=$(git -C "$member" branch --show-current 2>/dev/null)
      echo_info "Running .ws-init delete from $(basename "$main_worktree")..."
      ( cd "$member" && WS_DEST="$member" WS_BRANCH="$member_branch" WS_MAIN_CLONE="$main_worktree" \
          "$main_worktree/.ws-init" delete ) \
        || echo_warn ".ws-init delete failed for $member — continuing with deletion"
    fi

    echo_info "Removing worktree $member (branch kept)..."
    git -C "$main_worktree" worktree remove --force "$member" 2>/dev/null
  done

  # Remove whatever remains of the workspace dir.
  [[ -d "$workspace" ]] && rm -rf "$workspace"

  # Free every port the workspace leased (any repo's .ws-init reserves under
  # the owner key "ws:<name>" — see scripts/ports). Generic: the workspace layer
  # only knows the owner key, never which ports a repo wanted.
  if [[ -x "$HOME/src/dev_setup/scripts/ports" ]]; then
    "$HOME/src/dev_setup/scripts/ports" release "ws:$short" >/dev/null \
      || echo_warn "Failed to release ports for ws:$short — run 'ports release ws:$short'"
  fi
  echo_success "Deleted workspace: $workspace"

  # LAST, always: killing the window SIGHUPs this very shell when wsd was run
  # from inside the workspace's own window. Anything below here would silently
  # not run — which is exactly how leases used to leak.
  "$_WS_TPC" kill mob-editor "$short"
}

# wsc [--bg] <branch> — create a workspace from the repo in the current directory.
# Works whether you're in the repo's main clone or inside an existing worktree:
# it resolves the main clone (where the true source lives) and bases the new
# branch off origin's default, so you can spin up a fresh workspace from within
# another one without inheriting its branch. --bg creates the tmux windows
# without switching to them.
function wsc() {
  local bg="" branch="" arg
  for arg in "$@"; do
    case "$arg" in
      --bg) bg="--bg" ;;
      *) branch="$arg" ;;
    esac
  done
  if [[ -z "$branch" ]]; then
    echo_failure "Usage: wsc [--bg] <branch-name>"
    return 1
  fi
  # The first `git worktree list` entry is the main clone, even from a worktree.
  local main_clone_parts=(${=$(git worktree list 2>/dev/null | head -1)})
  local main_clone="${main_clone_parts[1]}"
  if [[ -z "$main_clone" ]]; then
    echo_failure "Not in a git repo"
    return 1
  fi
  _ws_create "$main_clone" "$branch" $bg
}

# wsa <repo> [repo...] — add repos to the workspace the current dir lives in.
function wsa() {
  if [[ -z "$1" ]]; then
    echo_failure "Usage: wsa <repo> [repo2 ...]"
    return 1
  fi
  local workspace=$(_ws_from_pwd)
  if [[ -z "$workspace" ]]; then
    echo_failure "Must be inside a workspace under $WS_ROOT"
    return 1
  fi
  _ws_add "$workspace" "$@"
  [[ -n "$_WS_LAST_ADDED" ]] && cd "$_WS_LAST_ADDED"
}

# wsd [name|path] — delete a workspace (defaults to the one you're standing in).
function wsd() {
  local workspace
  if [[ -n "$1" ]]; then
    if [[ "$1" == */* || "$1" == "~"* ]]; then
      workspace="${1/#\~/$HOME}"
    else
      workspace="$WS_ROOT/$1"
    fi
  else
    workspace=$(_ws_from_pwd)
    if [[ -z "$workspace" ]]; then
      echo_failure "Not inside a workspace; pass one: wsd <name>"
      return 1
    fi
  fi

  # If we're standing inside the workspace we're deleting, step out first.
  local cwd=$(pwd -P)
  [[ "$cwd" == "$workspace"* ]] && cd "$HOME/src"

  _ws_delete "$workspace"
}

# wsp [--yes] [--force] — purge inactive workspaces: delete every workspace
# with no open tmux window in the mob pair. A window in EITHER half counts as
# active (spawned Claudes live in mob-shell, the human in mob-editor).
# Workspaces with uncommitted changes are skipped unless --force — committed
# work is safe either way (branches are kept), but dirt would be lost.
# --yes skips the confirmation, for non-interactive callers; without it a
# tty-less run safely aborts at the prompt.
function wsp() {
  local yes="" force="" arg
  for arg in "$@"; do
    case "$arg" in
      --yes|-y)   yes=1 ;;
      --force|-f) force=1 ;;
      *) echo_failure "Usage: wsp [--yes] [--force]"; return 1 ;;
    esac
  done

  # With no mob sessions at all (tmux down, fresh boot) EVERY workspace would
  # look inactive — refuse rather than purge the world.
  if ! tmux has-session -t mob-editor 2>/dev/null && ! tmux has-session -t mob-shell 2>/dev/null; then
    echo_failure "No mob-editor/mob-shell tmux sessions running — every workspace would count as inactive. Refusing; use wsd for individual deletes."
    return 1
  fi
  # Duplicated windows are named <base>_<n> (tmux-pair-cmd.sh copy), so index
  # each name both verbatim and with the _<n> suffix stripped — an open X_2
  # keeps workspace X alive, while a workspace literally named gpt_2 still
  # matches its own verbatim window name.
  local open_windows=$(
    { tmux list-windows -t mob-editor -F '#{window_name}' 2>/dev/null
      tmux list-windows -t mob-shell  -F '#{window_name}' 2>/dev/null; } \
    | awk '{ print; if (sub(/_[0-9]+$/, "")) print }' | sort -u)

  local ws short repo dirty label
  local -a purge labels skipped
  for ws in "$WS_ROOT"/*(/N); do
    short=$(basename "$ws")
    print -r -- "$open_windows" | grep -qxF "$short" && continue
    dirty=0
    for repo in "$ws"/*(/N); do
      [[ -e "$repo/.git" ]] || continue
      [[ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]] && dirty=1
    done
    if (( dirty )) && [[ -z "$force" ]]; then
      skipped+=("$short")
      continue
    fi
    purge+=("$ws")
    label="$short"
    (( dirty )) && label="$short (UNCOMMITTED CHANGES)"
    labels+=("$label")
  done

  (( ${#skipped} )) && echo_warn "Skipping ${#skipped} with uncommitted changes (use --force to include): ${(j:, :)skipped}"
  if (( ${#purge} == 0 )); then
    echo_success "Nothing to purge — every workspace has an open tmux window."
    return 0
  fi

  echo_info "Inactive workspaces to delete (${#purge}):"
  for label in "${labels[@]}"; do print -r -- "  $label"; done
  if [[ -z "$yes" ]] && ! _ws_confirm "Delete these ${#purge} workspace(s)?"; then
    echo_failure "Aborted — nothing deleted."
    return 1
  fi

  # Step out first if we're standing inside one of the doomed workspaces.
  local cwd=$(pwd -P)
  for ws in "${purge[@]}"; do
    [[ "$cwd" == "$ws"* ]] && { cd "$HOME/src"; break; }
  done

  for ws in "${purge[@]}"; do
    _ws_delete "$ws"
  done
}

# ws — TV picker over workspaces (enter drills into a workspace's repos).
function ws() {
  tv ws
}

# wt — TV picker over the worktrees in the current workspace.
function wt() {
  local workspace=$(_ws_from_pwd)
  if [[ -z "$workspace" ]]; then
    echo_failure "Not inside a workspace (cd into one under $WS_ROOT first)"
    return 1
  fi
  echo "$workspace" > "$WS_STATE"
  tv wt
}

# Complete wsa with the repos in ~/src (excluding the workspaces dir).
_ws_src_repos() {
  local -a repos
  repos=("$HOME"/src/*(/N:t))
  repos=(${repos:#${WS_ROOT:t}})
  compadd -a repos
}
# Complete wsd with the existing workspace names.
_ws_workspaces() {
  local -a workspaces
  workspaces=("$WS_ROOT"/*(/N:t))
  compadd -a workspaces
}
if (( $+functions[compdef] )); then
  compdef _ws_src_repos wsa
  compdef _ws_workspaces wsd
fi
