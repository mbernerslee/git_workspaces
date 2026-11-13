# git_workspaces — multi-repo git worktrees, one branch each

A **workspace** groups per-repo worktrees you work on together under
`$WS_ROOT/<short>/<repo>/` (default `~/src/workspaces`). The workspace **is** a
branch: every repo in it uses the same branch name. Main clones live at
`$WS_SRC_ROOT/<repo>` (default `~/src`) and are never touched.

Worktrees come **fully set up**: `deps/`, `_build/`, `node_modules/` are
copied from the repo's latest build [snapshot](#snapshots), or else the main
clone (COW where the filesystem has it), with source mtimes put back so warm
Elixir builds stay warm; `.env`, `.mcp.json`,
`.claude/settings.local.json`, `CLAUDE.local.md` are symlinked; a tracked or
generated `.envrc` is `direnv allow`ed.

How a workspace is *presented* — a tmux window, a herdr workspace, nothing —
is not this repo's business. Two kinds of hook carry everything that varies:

| hook | question it answers | owner | lives in |
|---|---|---|---|
| `.ws-init` (`pre`/`post`/`switch`/`delete`/`build`) | how to prepare *this repo's* worktree | the repo | the repo's main clone, git-excluded |
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
    wsd [--force] [name...] delete workspaces (worktrees + dir; branches kept);
                           several names = each in turn, carrying on past refusals
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

## Reading the output

Every line says who is talking, so it's always clear what code is running:

| line | means |
|---|---|
| `[ws:<step>] …` | **this library** (`git_workspaces.zsh`) starting a step: `create`, `add`, `delete`, `purge`, `snapshot`, `git`, `copy`, `mtimes`, `links`, `done`. A command's first header also prints where the library lives. |
| `  detail` | more about the current step (indented, no brackets); `  ✓` / `  ⚠` / `  ✗` = done / warning / failure |
| `[hook:<name>] <file>` | handing over to a **hook**: `<file>` is the code that runs (`a → b` when it's a symlink — `b` is the real file) |
| `  │ …` | that hook's (or git's) own output, verbatim |

After a hook, the next line is always a `[ws:…]` header again — back in this
library. For example:

    [ws:create] workspace 'feat' (branch 'feat') from ploy-server  (git_workspaces: ~/src/git_workspaces)
    [ws:snapshot] ploy-server: using snapshot d632732f8a11 (built 22m ago) — ~/src/.ws-snapshots/…
    [hook:.ws-init pre] ~/src/ploy-server/.ws-init → ~/src/dev_setup/ploy/server/ws-init  (in ~/src/ploy-server)
    [ws:git] ploy-server: worktree at ~/src/workspaces/feat/ploy-server — new branch 'feat' from …
      │ Preparing worktree (new branch 'feat')
    [ws:copy] ploy-server: build dirs deps/ _build/ from the snapshot …
    [ws:mtimes] ploy-server: source file mtimes as recorded in the snapshot
      18440 restored, 0 changed since the build kept fresh
    [hook:.ws-init post] ~/src/ploy-server/.ws-init → ~/src/dev_setup/ploy/server/ws-init  (in …/feat/ploy-server)
      │ DBs ready for 'feat'
    [hook:created] ~/.config/ws/hooks/created
    [ws:done] workspace 'feat' ready

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
- `build` — compile the checkout it's run in (cwd = `WS_DEST` = the repo's
  snapshot checkout). Defining `ws_build` opts the repo into
  [snapshots](#snapshots). Only `ws-snapshot.sh` runs it.

`pre` also gets `WS_SNAPSHOT=<sha>` when the worktree is starting from a
snapshot (empty otherwise), so it can skip work the snapshot already did —
pulling, waiting for a build.

## Snapshots

A **snapshot** is a repo's compiled build output — `deps/`, `_build/`,
`node_modules/` — for one commit of origin's default branch, plus the mtimes of
the sources it was compiled from. New worktrees start from the latest one, so
they open with nothing to compile:

1. **Making one** (`ws-snapshot.sh`, on a schedule): `git fetch` in the main
   clone; if origin's default branch is at a commit with no snapshot yet, move
   the repo's **snapshot checkout** (a detached worktree under
   `$WS_SNAPSHOT_ROOT/<repo>/checkout`) to it, run `.ws-init build` there, then
   clone the build dirs + record the mtimes into `$WS_SNAPSHOT_ROOT/<repo>/<sha>/`
   and point `latest` at it. A failed build keeps the previous snapshot. When
   origin hasn't moved, a run is just the fetch. Several repos are snapshotted
   in parallel, each repo's output printed as one block; each snapshot records
   how long its build took (`took=` in its `commit` file, shown by `status`).
2. **Using one** (any workspace create/add): the branch is based on the
   snapshot's commit (so up to one schedule interval behind origin), the build
   dirs are cloned from the snapshot, and each source file gets the mtime it had
   when compiled — except files that differ from that commit, which keep "now"
   so the build tool sees them as changed.

A snapshot is used only if origin was confirmed to match it within
`WS_SNAPSHOT_MAX_AGE`; otherwise — or with `WS_FRESH=1`, or for a repo with no
`ws_build` — the worktree is set up the old way: build dirs and mtimes from the
main clone, branch from the local default branch. The main clone is never
touched beyond `git fetch`.

    ws-snapshot.sh --all            # every repo whose .ws-init defines ws_build
    ws-snapshot.sh <repo>... [--force]
    ws-snapshot.sh status           # freshness, whether in use, failures
    ws-snapshot.sh rm <repo>        # drop a repo's snapshots + checkout
    WS_FRESH=1 wsc <branch>         # ignore snapshots: latest main, old path

Compiled output can contain the absolute path of the checkout it was built in
(`__DIR__`, compile-time file paths), so code that depends on those paths at
runtime sees the snapshot checkout's — the same caveat as copying from the main
clone.

## Configuration

| var | default | |
|---|---|---|
| `WS_ROOT` | `~/src/workspaces` | where workspaces live (exported) |
| `WS_SRC_ROOT` | `~/src` | where main clones live (exported) |
| `WS_HOOKS_DIR` | `~/.config/ws/hooks` | user hooks |
| `WS_STATE` | `$XDG_RUNTIME_DIR/tv-ws` or `/tmp/tv-ws` | tv "current workspace" handoff (exported) |
| `WS_SNAPSHOT_ROOT` | `$WS_SRC_ROOT/.ws-snapshots` | where snapshots live (same filesystem as the workspaces, for COW) |
| `WS_SNAPSHOT_MAX_AGE` | `86400` | seconds since origin was last confirmed to match a snapshot before it stops being used |
| `WS_SNAPSHOT_KEEP` | `3` | snapshots kept per repo |
| `WS_FRESH` | unset | `1` = don't start new worktrees from snapshots |

## Tests

    tests/ws_hooks_test.sh     # the user-hook contract (what a hook set is written against)
    tests/ws_init_test.sh      # the .ws-init protocol
    tests/ws_snapshot_test.sh  # snapshots: making, using, falling back, mtimes

All build real git repos in a temp dir and refuse to run if `WS_ROOT` isn't
honoured, so they never touch your real workspaces.
