# git_workspaces — multi-repo git worktrees, one branch each

A **workspace** groups per-repo worktrees you work on together under
`$WS_ROOT/<short>/<repo>/` (default `~/src/workspaces`). The workspace **is** a
branch: every repo in it uses the same branch name. Main clones live at
`$WS_SRC_ROOT/<repo>` (default `~/src`) and are never touched.

Worktrees come **fully set up**: `deps/`, `_build/`, `node_modules/` are
copied from the main clone (COW where the filesystem has it) with mtimes
preserved so warm Elixir builds stay warm; `.env`, `.mcp.json`,
`.claude/settings.local.json`, `CLAUDE.local.md` are symlinked; a tracked or
generated `.envrc` is `direnv allow`ed.

How a workspace is *presented* — a tmux window, a herdr workspace, nothing —
is not this repo's business. Two kinds of hook carry everything that varies:

| hook | question it answers | owner | lives in |
|---|---|---|---|
| `.ws-init` (`pre`/`post`/`switch`/`delete`) | how to prepare *this repo's* worktree | the repo | the repo's main clone, git-excluded |
| user hooks (`pre-create`/`created`/`switch`/`pre-delete`/`deleted`/`active`) | how to show a workspace *on this machine* | you | `$WS_HOOKS_DIR` (default `~/.config/ws/hooks`) |

## Install

    export PATH="$HOME/src/git_workspaces/bin:$PATH"
    source ~/src/git_workspaces/git_workspaces.zsh      # from your zshrc
    ln -s ~/src/git_workspaces/tv/*.toml ~/.config/television/cable/   # tv pickers

Requires zsh, git, and [television](https://github.com/alexpasmantier/television)
for the `ws`/`wt` pickers.

## Commands

    wsc [--bg] <branch>    create a workspace from the repo you're in (--bg: tell the
                           `created` hook not to switch to it)
    wsa <repo> [repo...]   add repos to the workspace you're standing in
    wsd [--force] [name]   delete a workspace (worktrees + dir; branches kept)
    wsp [--yes] [--force]  purge every workspace the `active` hook doesn't list
    ws                     tv picker: workspaces — enter=switch, ctrl-g=drill into
                           repos, ctrl-n=new, ctrl-d=delete
    wt                     tv picker: worktrees in this workspace — enter=switch, ctrl-n=add

Scripts in `bin/` back the pickers and give agents a non-interactive surface:
`ws-repos.sh [list|add <repo>…]` (what's in this workspace, what's addable),
`ws-create.sh`, `ws-delete.sh`, `ws-switch.sh`, `wt-add.sh`, `wt-list.sh`,
`wt-switch.sh`, `src-repos-list.sh`. Library functions for scripting:
`_ws_create <repo|path> <branch> [--bg|--no-window]`, `_ws_add`, `_ws_delete
<dir> [--force]`, `_ws_from_pwd`, `_ws_short_name <branch>` (the dir name a
branch maps to: `/`→`-`, ≤25 chars).

Inside a workspace the shell exports `WS_NAME=<short>` (a `chpwd` hook), so
per-workspace tooling — e.g. the `ports` registry (`~/src/ports`) —
can find its identity without sniffing `$PWD`.

## User hooks

Optional executables in `$WS_HOOKS_DIR`. A missing hook means that step is
skipped. Hooks run **synchronously**, in the caller's cwd, with context set
explicitly for that process (so a shell's exported `WS_NAME` never leaks into a
hook about a different workspace):

| var | meaning |
|---|---|
| `WS_NAME` | workspace short name |
| `WS_DIR` | `created`/`switch`: where the presentation should land (the repo just added; what `.ws-init switch` chose; else the root). `pre-*`/`deleted`: the workspace root |
| `WS_ROOT_DIR` | the workspace root |
| `WS_BRANCH` | the workspace branch |
| `WS_BG` | `1` when the caller asked for background (`wsc --bg`) |

| hook | when | contract |
|---|---|---|
| `pre-create` | before anything is made | non-zero aborts creation (its stderr is shown) |
| `created` | after every member is set up | exit status ignored (warns) |
| `switch` | on `ws`/`wt` switching | exit status ignored (warns) |
| `pre-delete` | before deletion | 1 = refuse, 0 = go, other = unknown (warn, go); `--force` skips it. `wsp` runs it quietly per candidate, `_ws_delete` again for each one deleted |
| `deleted` | the very last thing `_ws_delete` does, after `rm -rf` | may kill the caller's own window (SIGHUP); `_ws_delete` still returns 0 |
| `active` | `wsp` only, no context vars | print the names of workspaces still "open", one per line; non-zero = can't tell → `wsp` refuses; missing = every workspace is a candidate |

A tmux-pair implementation lives in the author's dev_setup (`ws-hooks/`). A
herdr one would be the same six files calling `herdr` instead.

## `.ws-init` (per repo)

A single executable `.ws-init` in the main clone (typically git-excluded, so
it applies to every worktree without being committed) is invoked with the
phase as `$1` and `WS_DEST` / `WS_BRANCH` / `WS_MAIN_CLONE` in the env:

- `pre` — BEFORE the worktree is created (cwd = main clone; dest not made).
  Non-zero **aborts** creation — a precondition (e.g. a failed build). A
  `git pull` here should warn and carry on when it fails, as the tooling's own
  `git fetch origin` does: an unreachable GitHub must never block a workspace,
  since the branch is based on the local default branch anyway.
- `post` — AFTER it is fully set up (cwd = the new worktree). Wire up
  per-workspace state: ports, a cloned DB, a generated `.envrc`, …
- `switch` — when switching TO the workspace (cwd = the worktree). Print a
  directory to make the switch land there instead of the workspace root; the
  first member to print an existing directory wins.
- `delete` — BEFORE the worktree is removed (cwd = the worktree). Undo what
  `post` created outside the workspace dir. Failure warns, never blocks.

## Configuration

| var | default | |
|---|---|---|
| `WS_ROOT` | `~/src/workspaces` | where workspaces live (exported) |
| `WS_SRC_ROOT` | `~/src` | where main clones live (exported) |
| `WS_HOOKS_DIR` | `~/.config/ws/hooks` | user hooks |
| `WS_STATE` | `$XDG_RUNTIME_DIR/tv-ws` or `/tmp/tv-ws` | tv "current workspace" handoff (exported) |

## Tests

    tests/ws_hooks_test.sh   # the user-hook contract (what a hook set is written against)
    tests/ws_init_test.sh    # the .ws-init protocol

Both build real git repos in a temp dir and refuse to run if `WS_ROOT` isn't
honoured, so they never touch your real workspaces.
