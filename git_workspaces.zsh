# Workspaces (multi-repo git worktrees)
#
# A "workspace" groups per-repo worktrees you work on together under
#   $WS_ROOT/<short>/<repo>/            (default ~/src/workspaces)
# The workspace IS a branch: every repo in it uses the same branch name.
# Main clones live at $WS_SRC_ROOT/<repo> (default ~/src) and are never touched.
#
# How a workspace is *presented* (a tmux window, a herdr workspace, nothing) is
# not this file's business: at each lifecycle point it runs an optional user
# hook from $WS_HOOKS_DIR (default ~/.config/ws/hooks) — see _ws_hook below.
#
# Commands:
#   wsc [--bg] <branch>   create a workspace from the current repo (--bg: tell
#                         the `created` hook not to switch to it)
#   wsa <repo> [repo...]  add repos to the workspace you're standing in
#   wsd [-f] [name|path ...]  delete workspaces (worktrees + dir; branches
#                         kept); several names = delete each, carrying on past
#                         refusals; no name = the one you're in, and you stay
#                         in it if the delete is refused (so `wsd -f` retries)
#   wsp [--yes] [--force] purge every workspace the `active` hook doesn't list
#                         (--force includes ones with uncommitted changes or a
#                         refusing pre-delete hook)
#   ws                    TV: workspaces — enter=switch, ctrl-g=drill into repos,
#                         ctrl-n=new, ctrl-d=delete
#   wt                    TV: worktrees in the current workspace — enter=switch,
#                         ctrl-n=add
#
#   ws-snapshot.sh        make / inspect build snapshots new worktrees start
#                         from (see "Snapshots" below); WS_FRESH=1 bypasses them
#
# (ctrl-g avoids the built-in ctrl-l=toggle_layout that shadowed the drill key.)
#
# Sourced from the user's zshrc (where the real echo_*/master_branch live) AND
# directly by the tv helper scripts in bin/w{s,t}-*.sh — so the helpers
# below are defined only as fallbacks when sourced standalone.

export WS_ROOT="${WS_ROOT:-$HOME/src/workspaces}"
export WS_SRC_ROOT="${WS_SRC_ROOT:-$HOME/src}"
export WS_HOOKS_DIR="${WS_HOOKS_DIR:-$HOME/.config/ws/hooks}"
# tv hands the "current workspace" to the wt channel here. Exported: the tv
# cables run in tv's child shell and read $WS_STATE.
export WS_STATE="${WS_STATE:-${XDG_RUNTIME_DIR:-/tmp}/tv-ws}"
# Build snapshots (see "Snapshots" below): where they live, how old the last
# successful check against origin may be before workspaces stop trusting it,
# and how many to keep per repo. A dot-dir, so the ~/src repo pickers skip it.
export WS_SNAPSHOT_ROOT="${WS_SNAPSHOT_ROOT:-$WS_SRC_ROOT/.ws-snapshots}"
export WS_SNAPSHOT_MAX_AGE="${WS_SNAPSHOT_MAX_AGE:-86400}"
export WS_SNAPSHOT_KEEP="${WS_SNAPSHOT_KEEP:-3}"
# Directory of this file (lib/ holds helpers). %x = the file being sourced.
_WS_HOME="${${(%):-%x}:A:h}"
# The gitignored build-output dirs carried into a new worktree (from a snapshot,
# or else from the main clone). deps/ before _build/: _build/<env>/lib/<dep>/
# {src,include,priv} are relative symlinks into deps/.
_WS_ARTIFACT_DIRS=(deps _build node_modules)

# Catppuccin colours matching zshrc's INFO=$TEAL / SUCCESS=$GREEN / FAILURE=$RED.
(( $+functions[echo_info] ))    || echo_info()    { print -P "%F{#8bd5ca}$*%f"; }
(( $+functions[echo_success] )) || echo_success() { print -P "%F{#a6da95}$*%f"; }
(( $+functions[echo_failure] )) || echo_failure() { print -P "%F{#ed8796}$*%f" >&2; }
# Peach, for warnings that aren't outright failures.
(( $+functions[echo_warn] ))    || echo_warn()    { print -P "%F{#f5a97f}$*%f" >&2; }

# ── Output ───────────────────────────────────────────────────────────────────
# Every line says WHO is talking, so it's always clear what code is running:
#
#   [ws:<step>] …          THIS library (git_workspaces) starting <step>
#     detail               more about that step — indented, no brackets
#   [hook:<name>] <file>   handing over to a hook; <file> is the code that runs
#     │ …                  that hook's (or git's) own output, verbatim
#
# After a hook, the next line is always a [ws:…] header again — back in this
# library. Warnings (⚠) and failures (✗) are indented details, on stderr. The
# first header of each command also names where this library lives.
_ws_tilde()  { print -r -- "${1/#$HOME/~}"; }
_ws_step()   { print -Pn "%F{#8bd5ca}[ws:$1]%f "; print -r -- "${*:2}"; }
# _ws_step_top <step> <msg> — a command's first header, plus the library path.
_ws_step_top() {
  print -Pn "%F{#8bd5ca}[ws:$1]%f "; print -rn -- "${*:2}"
  print -P "  %F{#6e738d}(git_workspaces: $(_ws_tilde "$_WS_HOME"))%f"
}
_ws_detail() { print -r -- "  $*"; }
_ws_ok()     { print -Pn "%F{#a6da95}"; print -rn -- "  ✓ $*"; print -P "%f"; }
_ws_warn()   { { print -Pn "%F{#f5a97f}"; print -rn -- "  ⚠ $*"; print -P "%f"; } >&2; }
_ws_fail()   { { print -Pn "%F{#ed8796}"; print -rn -- "  ✗ $*"; print -P "%f"; } >&2; }
# _ws_indent / _ws_nest — prefix every line of stdin: "  " for this library's
# own helper output, "  │ " for a subprocess's (hook, git) output.
_ws_indent() { local l; while IFS= read -r l || [[ -n "$l" ]]; do print -r -- "  $l"; done; }
_ws_nest()   { local l; while IFS= read -r l || [[ -n "$l" ]]; do print -r -- "  │ $l"; done; }
# _ws_nested <cmd> [args...] — run it with stdout+stderr nested; returns its rc.
_ws_nested() { { "$@" } 2>&1 | _ws_nest; return ${pipestatus[1]}; }
# _ws_init_run <phase> <cwd> <main_clone> <dest> <branch> [snapshot-sha] — run
# the repo's `.ws-init <phase>` in <cwd> with its context env (see
# _ws_setup_worktree). Wrap in _ws_nested to show its output as a hook's.
_ws_init_run() {
  ( cd "$2" && WS_DEST="$4" WS_BRANCH="$5" WS_MAIN_CLONE="$3" WS_SNAPSHOT="${6:-}" "$3/.ws-init" "$1" )
}
# _ws_hook_header <name> <file> [note] — announce a hook; a symlinked file
# shows where it really lives.
_ws_hook_header() {
  local where=$(_ws_tilde "$2")
  [[ -L "$2" ]] && where+=" → $(_ws_tilde "${2:A}")"
  print -Pn "%F{#c6a0f6}[hook:$1]%f "; print -r -- "$where${3:+  $3}"
}

# _ws_hook <name> [VAR=value ...] — run the user hook $WS_HOOKS_DIR/<name> if
# it exists and is executable, with the given context vars set for THAT
# process only (so a shell-exported WS_NAME never leaks into a hook about a
# different workspace). Runs synchronously in the caller's cwd.
# Returns 127 when there is no such hook, otherwise the hook's exit status —
# except that a hook which itself died with 127 ("command not found", e.g. a
# tool missing from PATH) is reported as 126, so it can never pass for "no hook".
#
# Hooks and their contract (all optional; context: WS_NAME, WS_DIR, WS_ROOT_DIR,
# WS_BRANCH, and WS_BG=1 when the caller asked for background):
#   pre-create  before anything is made; non-zero ABORTS creation
#   created     after every member is set up; WS_DIR = the new repo worktree
#   switch      on ws/wt switching; WS_DIR = where the switch should land
#   pre-delete  before deletion; 1 = refuse, 0 = go, other = unknown (warn, go)
#   deleted     LAST thing _ws_delete does, after the dir is gone
#   active      wsp only, no context vars: print the names of workspaces still
#               "open" (one per line); non-zero = can't tell → wsp refuses
_ws_hook() {
  local name="$1"; shift
  local hook="$WS_HOOKS_DIR/$name"
  [[ -x "$hook" ]] || return 127
  env "$@" "$hook"; local rc=$?
  (( rc == 127 )) && rc=126
  return $rc
}

# _ws_hook_shown <name> [VAR=value ...] — _ws_hook, announced with a
# [hook:<name>] header and its output nested. For hooks whose output is for the
# human; `switch` and `active` (whose stdout is consumed) use _ws_hook.
_ws_hook_shown() {
  local hook="$WS_HOOKS_DIR/$1"
  [[ -x "$hook" ]] || return 127
  _ws_hook_header "$1" "$hook"
  _ws_nested _ws_hook "$@"
}

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
# the fs has it. macOS: clone the whole tree in one clonefile(2) call
# (lib/ws_clone.py — ~15x faster than cp -Rc, which clones file by file); if
# that can't be used (dest exists, other volume, no python3), cp -Rc. Elsewhere
# GNU cp (--reflink=auto uses COW on btrfs/xfs, plain copy on ext4).
_ws_copy() {
  if [[ "$OSTYPE" == darwin* ]]; then
    if [[ ! -e "$2" && -d "$1" ]] && command -v python3 >/dev/null 2>&1; then
      python3 "$_WS_HOME/lib/ws_clone.py" "$1" "$2" 2>/dev/null && return 0
      rm -rf "$2"   # never let cp copy INTO a half-made clone
    fi
    cp -Rc "$1" "$2"
  else
    cp -a --reflink=auto "$1" "$2"
  fi
}

# _ws_main_branch <main_clone> — the repo's default branch name: origin/HEAD,
# else whichever of main/master exists locally, else "main".
_ws_main_branch() {
  local main_clone="$1" b
  b=$(git -C "$main_clone" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
  if [[ -z "$b" ]]; then
    for b in main master ""; do
      [[ -n "$b" ]] && git -C "$main_clone" show-ref --verify --quiet "refs/heads/$b" && break
    done
  fi
  echo "${b:-main}"
}

# _ws_mtimes save|restore … — see lib/ws_mtimes.py (one process for all files).
_ws_mtimes() {
  if ! command -v python3 >/dev/null 2>&1; then
    _ws_warn "python3 not found — skipping mtimes (expect a fuller recompile)"
    return 1
  fi
  python3 "$_WS_HOME/lib/ws_mtimes.py" "$@"
}

# Resolve a repo argument (bare name under ~/src, or a path) to a main-clone path.
_ws_resolve_main_clone() {
  local arg="$1"
  if [[ "$arg" == */* || "$arg" == "~"* ]]; then
    echo "${arg/#\~/$HOME}"
  else
    echo "$WS_SRC_ROOT/$arg"
  fi
}

# Echo the workspace dir that the current directory lives in (empty if none).
_ws_from_pwd() {
  local cwd=$(pwd -P)
  # -q: don't fire chpwd hooks from this subshell — _ws_export_name is one of
  # them and calls back here, which would recurse without bound.
  local root=$(cd -q "$WS_ROOT" 2>/dev/null && pwd -P)
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

# ── Snapshots ────────────────────────────────────────────────────────────────
# A snapshot is a repo's compiled build output (deps/, _build/, node_modules/)
# for ONE commit of origin's default branch, plus the mtimes of the sources it
# was compiled from. New worktrees start from the latest one — branch based on
# its commit, build dirs cloned from it, mtimes put back — so they open with
# nothing to compile. Layout, per repo:
#
#   $WS_SNAPSHOT_ROOT/<repo>/
#     checkout/     a detached worktree of the main clone; builds happen HERE
#     <sha>/        a finished snapshot: deps/ _build/ … + mtimes + commit (info)
#     latest ->     the newest finished snapshot
#     checked       when origin was last confirmed to match `latest`
#     build.log     the last build's output;  last-error  only while failing
#     lock/         held while a snapshot is being made
#
# Opt-in per repo: its .ws-init defines ws_build (the `build` phase), which
# compiles the checkout it's run in (cwd = WS_DEST = the checkout). The main
# clone is never touched beyond `git fetch`. Made by `ws-snapshot.sh`, normally
# on a schedule.

_ws_snapshot_dir() { echo "$WS_SNAPSHOT_ROOT/${1:t}"; }

# _ws_snapshot_field <snapshot-dir> <key> — a value from its `commit` file.
_ws_snapshot_field() { sed -n "s/^$2=//p" "$1/commit" 2>/dev/null; }

# _ws_age <epoch> — "42s" / "7m" / "3h" / "2d" since then.
_ws_age() {
  local s=$(( $(date +%s) - ${1:-0} ))
  if (( s < 60 )); then echo "${s}s"
  elif (( s < 3600 )); then echo "$(( s / 60 ))m"
  elif (( s < 86400 )); then echo "$(( s / 3600 ))h"
  else echo "$(( s / 86400 ))d"; fi
}

# _ws_snapshot_opted_in <main_clone> — does its .ws-init define a build phase?
_ws_snapshot_opted_in() {
  [[ -x "$1/.ws-init" ]] && grep -q 'ws_build' "$1/.ws-init" 2>/dev/null
}

# _ws_snapshot_usable <main_clone> — echo the latest snapshot's dir if a new
# worktree may start from it: it exists, its commit is in the repo, and origin
# was confirmed to match it within WS_SNAPSHOT_MAX_AGE (so a dead scheduler
# can't silently base everything on an ancient main).
_ws_snapshot_usable() {
  local main_clone="$1" sdir=$(_ws_snapshot_dir "$1")
  local snap="$sdir/latest"
  [[ -f "$snap/commit" && -f "$snap/mtimes" ]] || return 1
  snap="${snap:A}"
  local sha=$(_ws_snapshot_field "$snap" sha)
  [[ -n "$sha" ]] && git -C "$main_clone" cat-file -e "$sha^{commit}" 2>/dev/null || return 1
  local checked=$(cat "$sdir/checked" 2>/dev/null)
  (( $(date +%s) - ${checked:-0} <= WS_SNAPSHOT_MAX_AGE )) || return 1
  echo "$snap"
}

# _ws_snapshot_point_latest <sdir> <sha> — repoint `latest` atomically.
_ws_snapshot_point_latest() {
  ln -sfn "$2" "$1/latest.new" || return 1
  if [[ "$OSTYPE" == darwin* ]]; then mv -fh "$1/latest.new" "$1/latest"
  else mv -fT "$1/latest.new" "$1/latest"; fi
}

# _ws_snapshot <repo|path> [--force] — bring the repo's snapshot up to date with
# origin's default branch: fetch; if that commit has no snapshot yet (or
# --force), move the checkout to it, run `.ws-init build` there, and save the
# result as a new snapshot. Returns non-zero only when a build fails (or the
# repo isn't usable). Safe to run often: a no-op when nothing moved.
_ws_snapshot() {
  local main_clone=$(_ws_resolve_main_clone "$1") force=""
  [[ "${2:-}" == --force ]] && force=1
  local repo="${main_clone:t}"
  _ws_step_top snapshot "$repo"
  if [[ ! -e "$main_clone/.git" ]]; then
    _ws_fail "No git repo at $main_clone"; return 1
  fi
  if ! _ws_snapshot_opted_in "$main_clone"; then
    _ws_fail "$repo: its .ws-init has no build phase (ws_build) — nothing to snapshot"; return 1
  fi

  local sdir=$(_ws_snapshot_dir "$main_clone")
  mkdir -p "$sdir" || return 1
  if ! mkdir "$sdir/lock" 2>/dev/null; then
    local holder=$(cat "$sdir/lock/pid" 2>/dev/null)
    if [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null; then
      _ws_detail "a snapshot is already being made (pid $holder) — skipping"; return 0
    fi
    _ws_warn "clearing a stale snapshot lock (pid ${holder:-?} is gone)"
    rm -rf "$sdir/lock"; mkdir "$sdir/lock" || return 1
  fi
  echo $$ >"$sdir/lock/pid"

  {
    local main_branch=$(_ws_main_branch "$main_clone") fetched=1
    _ws_detail "git fetch origin in $(_ws_tilde "$main_clone")"
    if ! _ws_nested git -C "$main_clone" fetch -q origin; then
      fetched=""
      _ws_warn "couldn't fetch origin — snapshotting origin/$main_branch as last fetched"
    fi
    local sha=$(git -C "$main_clone" rev-parse -q --verify "origin/$main_branch^{commit}")
    if [[ -z "$sha" ]]; then
      _ws_fail "no origin/$main_branch to snapshot"; return 1
    fi

    if [[ -z "$force" && -f "$sdir/$sha/commit" ]]; then
      [[ "${${:-$sdir/latest}:A}" == "$sdir/$sha" ]] || _ws_snapshot_point_latest "$sdir" "$sha"
      [[ -n "$fetched" ]] && date +%s >"$sdir/checked"
      _ws_ok "origin/$main_branch is ${sha:0:12} — snapshot ${sha:0:12} is current, nothing to build"
      return 0
    fi

    local co="$sdir/checkout"
    if [[ ! -e "$co/.git" ]]; then
      _ws_detail "creating the snapshot checkout $(_ws_tilde "$co") at ${sha:0:12}, seeded from the main clone's build"
      git -C "$main_clone" worktree prune
      _ws_nested git -C "$main_clone" worktree add -q --detach "$co" "$sha" || { _ws_fail "couldn't create $co"; return 1; }
      # Seed it from the main clone's build (if any) so the first build is
      # incremental too. Same rules as a new workspace.
      local d
      for d in "${_WS_ARTIFACT_DIRS[@]}"; do
        [[ -d "$main_clone/$d" ]] && _ws_copy "$main_clone/$d" "$co/$d"
      done
      _ws_mtimes restore "$co" "$(git -C "$main_clone" rev-parse HEAD)" --from-dir "$main_clone" >/dev/null
    else
      # Only files that differ between the two commits are rewritten (and get
      # a fresh mtime), so the build recompiles just what changed.
      _ws_detail "moving the snapshot checkout $(_ws_tilde "$co") to ${sha:0:12} (origin/$main_branch)"
      _ws_nested git -C "$co" checkout -q --detach -f "$sha" || { _ws_fail "couldn't check out ${sha:0:12} in $co"; return 1; }
    fi

    _ws_hook_header ".ws-init build" "$main_clone/.ws-init" "(in the snapshot checkout; output → $(_ws_tilde "$sdir/build.log"))"
    ( cd "$co" && WS_DEST="$co" WS_BRANCH="" WS_MAIN_CLONE="$main_clone" WS_SNAPSHOT="$sha" \
        "$main_clone/.ws-init" build ) >"$sdir/build.log" 2>&1
    local rc=$?
    _ws_step snapshot "$repo: build of ${sha:0:12} finished (rc $rc)"
    if (( rc != 0 )); then
      printf 'sha=%s\nat=%s\nrc=%s\n' "$sha" "$(date +%s)" "$rc" >"$sdir/last-error"
      _ws_fail "build of ${sha:0:12} failed (rc $rc) — keeping the previous snapshot. Last lines of build.log:"
      tail -n 20 "$sdir/build.log" | _ws_nest >&2
      return 1
    fi

    _ws_detail "saving the build to $(_ws_tilde "$sdir/$sha")"
    local tmp="$sdir/$sha.tmp"
    rm -rf "$tmp"; mkdir "$tmp" || return 1
    for d in "${_WS_ARTIFACT_DIRS[@]}"; do
      [[ -d "$co/$d" ]] && { _ws_copy "$co/$d" "$tmp/$d" || { rm -rf "$tmp"; return 1; } }
    done
    _ws_mtimes save "$co" "$tmp/mtimes" || { rm -rf "$tmp"; return 1; }
    printf 'sha=%s\nbranch=%s\nbuilt=%s\n' "$sha" "$main_branch" "$(date +%s)" >"$tmp/commit"
    rm -rf "$sdir/$sha"
    mv "$tmp" "$sdir/$sha" && _ws_snapshot_point_latest "$sdir" "$sha" || return 1
    [[ -n "$fetched" ]] && date +%s >"$sdir/checked"
    rm -f "$sdir/last-error"

    # Keep the newest WS_SNAPSHOT_KEEP (never the one `latest` points at).
    local keep_target="${${:-$sdir/latest}:A}" n=0 s
    for s in "$sdir"/*(/Nom); do
      [[ "${s:t}" == (checkout|lock) || "$s" == "$keep_target" ]] && continue
      [[ "${s:t}" == *.tmp ]] && { rm -rf "$s"; continue; }
      [[ -f "$s/commit" ]] || continue
      (( ++n >= WS_SNAPSHOT_KEEP )) && rm -rf "$s"
    done
    _ws_ok "snapshot ${sha:0:12} ready — new worktrees start from it (latest)"
  } always {
    rm -rf "$sdir/lock"
  }
}

# _ws_snapshot_status <main_clone> — one human-readable block about it.
_ws_snapshot_status() {
  local main_clone="$1" repo="${1:t}" sdir=$(_ws_snapshot_dir "$1")
  local snap="$sdir/latest"
  print -r -- "$repo"
  if [[ -f "$snap/commit" ]]; then
    snap="${snap:A}"
    local sha=$(_ws_snapshot_field "$snap" sha) mb=$(_ws_snapshot_field "$snap" branch)
    local behind=$(git -C "$main_clone" rev-list --count "$sha..origin/$mb" 2>/dev/null)
    print -r -- "  latest:   ${sha:0:12}, built $(_ws_age "$(_ws_snapshot_field "$snap" built)") ago, ${behind:-?} commit(s) behind origin/$mb (as last fetched)"
    print -r -- "  checked:  $( [[ -f $sdir/checked ]] && echo "$(_ws_age "$(cat "$sdir/checked")") ago" || echo never)"
    if _ws_snapshot_usable "$main_clone" >/dev/null; then
      print -r -- "  in use:   yes — new worktrees start from it"
    else
      print -r -- "  in use:   NO — not confirmed against origin within ${WS_SNAPSHOT_MAX_AGE}s; new worktrees use the main clone"
    fi
  else
    print -r -- "  latest:   none"
  fi
  [[ -d "$sdir/lock" ]] && print -r -- "  building: now (pid $(cat "$sdir/lock/pid" 2>/dev/null))"
  [[ -f "$sdir/last-error" ]] && print -r -- "  FAILING:  last build of $(sed -n 's/^sha=//p' "$sdir/last-error" | cut -c1-12) failed $(_ws_age "$(sed -n 's/^at=//p' "$sdir/last-error")") ago — see $sdir/build.log"
  return 0
}

# Add a worktree for one repo into a workspace.
#   _ws_setup_worktree <main_clone> <branch> <dest>
# Resolves the branch (remote / local / new-from-master), copies build
# artifacts, restores tracked-file mtimes, symlinks env files. (Mix-manifest
# cwd rewriting was retired — ploy-server sets elixirc_options: [check_cwd: false].)
_ws_setup_worktree() {
  local main_clone="$1" branch="$2" dest="$3"
  local repo="${main_clone:t}"

  if [[ -d "$dest" ]]; then
    _ws_fail "Worktree directory already exists: $dest"
    return 1
  fi

  # Per-repo workspace hook. A single executable .ws-init in the main clone
  # (typically git-excluded / private, so it applies to every worktree without
  # being committed) is invoked with the phase as $1:
  #   pre    — BEFORE the worktree is created (cwd = main clone; dest not made)
  #   post   — AFTER it is fully set up       (cwd = the new worktree == WS_DEST)
  #   switch — when switching TO the workspace (ws picker; cwd = the worktree).
  #            Print a directory to stdout to make the switch land there
  #            instead of the workspace root. See _ws_switch_dir.
  #   delete — BEFORE the worktree is removed (cwd = the worktree, which still
  #            exists). Undo per-worktree resources `post` created OUTSIDE the
  #            workspace dir (cloned DBs, …). Failure warns but never blocks
  #            deletion. See _ws_delete.
  # The hook defines shell functions `ws_pre` / `ws_post` / `ws_switch` /
  # `ws_delete` and dispatches on the phase, defining only the phase(s) it
  # cares about. All phases get the same context via env: WS_DEST / WS_BRANCH /
  # WS_MAIN_CLONE. A non-zero `pre` ABORTS creation — it is a precondition.
  #   build  — not run here: `ws-snapshot.sh` runs it in the repo's snapshot
  #            checkout to compile a snapshot (see _ws_snapshot).
  #
  # When the repo has a usable snapshot (and WS_FRESH isn't set), the worktree
  # starts from it: a new branch is based on the snapshot's commit and the build
  # dirs come from the snapshot. `pre` is told via WS_SNAPSHOT=<sha> (empty when
  # not using one), so it can skip work the snapshot already did (pull, build).
  local snap="" snap_sha=""
  if [[ -z "${WS_FRESH:-}" ]] && snap=$(_ws_snapshot_usable "$main_clone"); then
    snap_sha=$(_ws_snapshot_field "$snap" sha)
    _ws_step snapshot "$repo: using snapshot ${snap_sha:0:12} (built $(_ws_age "$(_ws_snapshot_field "$snap" built)") ago) — $(_ws_tilde "$snap")"
  else
    snap=""
    if _ws_snapshot_opted_in "$main_clone"; then
      if [[ -n "${WS_FRESH:-}" ]]; then
        _ws_step snapshot "$repo: not using a snapshot (WS_FRESH set) — latest main, build from the main clone"
      else
        _ws_step snapshot "$repo: no usable snapshot (see ws-snapshot.sh status) — build from the main clone"
      fi
    fi
  fi

  if [[ -x "$main_clone/.ws-init" ]]; then
    _ws_hook_header ".ws-init pre" "$main_clone/.ws-init" "(in $(_ws_tilde "$main_clone"))"
    if ! _ws_nested _ws_init_run pre "$main_clone" "$main_clone" "$dest" "$branch" "$snap_sha"; then
      _ws_fail ".ws-init pre failed — aborting worktree creation for $repo"
      return 1
    fi
  fi

  local main_branch=$(_ws_main_branch "$main_clone")

  # A failed fetch (GitHub down, no network) is NOT fatal: the workspace is based
  # on the LOCAL default branch anyway, so the only cost is that the behind/ahead
  # check below reads a stale origin/<main>. Warn loudly and carry on.
  _ws_step git "$repo: fetch origin"
  if ! _ws_nested git -C "$main_clone" fetch origin; then
    _ws_warn "We couldn't fetch origin for $repo — continuing with the local $main_branch as it stands (it may be behind)"
  fi

  # New branches are based on the LOCAL default branch; whether that branch is
  # synced first is the per-repo .ws-init `pre` hook's decision (ploy's runs
  # `git pull`, so team repos still effectively base on origin). Divergence is
  # warned about so a stale or unpushed base is a visible choice, not a silent
  # surprise. Repos with no local copy of the default branch fall back to
  # origin's.
  local base_ref="origin/$main_branch"
  if [[ -n "$snap" ]]; then
    # Based on exactly the commit the snapshot compiled, so the copied build
    # matches the sources (up to one snapshot interval behind origin).
    base_ref="$snap_sha"
    local behind=$(git -C "$main_clone" rev-list --count "$snap_sha..origin/$main_branch" 2>/dev/null)
    (( behind > 0 )) && _ws_detail "the snapshot is $behind commit(s) behind origin/$main_branch (WS_FRESH=1 for the latest, built here)"
  elif git -C "$main_clone" show-ref --verify --quiet "refs/heads/$main_branch"; then
    base_ref="$main_branch"
    if git -C "$main_clone" show-ref --verify --quiet "refs/remotes/origin/$main_branch"; then
      local behind=$(git -C "$main_clone" rev-list --count "$main_branch..origin/$main_branch" 2>/dev/null)
      local ahead=$(git -C "$main_clone" rev-list --count "origin/$main_branch..$main_branch" 2>/dev/null)
      (( behind > 0 )) && _ws_warn "Local $main_branch is $behind commit(s) behind origin/$main_branch — basing the workspace on the stale local branch anyway"
      (( ahead > 0 )) && _ws_detail "local $main_branch has $ahead unpushed commit(s); the workspace will include them"
    fi
  fi

  local remote_exists=false local_exists=false
  git -C "$main_clone" show-ref --verify --quiet "refs/remotes/origin/$branch" 2>/dev/null && remote_exists=true
  git -C "$main_clone" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null && local_exists=true

  # A new workspace branch should not already exist anywhere. If it does, this
  # is unexpected — warn and require explicit confirmation before reusing it.
  if [[ "$remote_exists" == true || "$local_exists" == true ]]; then
    local where=""
    [[ "$local_exists" == true ]] && where="locally"
    [[ "$remote_exists" == true ]] && where="${where:+$where and }on origin"
    _ws_warn "Branch '$branch' already exists ($where) in $repo."
    _ws_warn "A new workspace branch should not already exist."
    if ! _ws_confirm "  Use the existing branch anyway?"; then
      _ws_fail "Aborted — branch '$branch' left untouched."
      return 1
    fi
  fi

  local -a add_args
  if [[ "$remote_exists" == true ]]; then
    _ws_step git "$repo: worktree at $(_ws_tilde "$dest") — existing remote branch '$branch'"
    add_args=("$dest" "$branch")
  elif [[ "$local_exists" == true ]]; then
    _ws_step git "$repo: worktree at $(_ws_tilde "$dest") — existing local branch '$branch'"
    add_args=("$dest" "$branch")
  else
    local from="$base_ref"
    [[ -n "$snap" ]] && from="the snapshot's commit ${snap_sha:0:12}"
    _ws_step git "$repo: worktree at $(_ws_tilde "$dest") — new branch '$branch' from $from"
    add_args=("$dest" -b "$branch" "$base_ref")
  fi
  _ws_nested git -C "$main_clone" worktree add "${add_args[@]}" || { _ws_fail "Failed to create worktree"; return 1; }

  # Copy the gitignored build dirs (deps/, _build/, node_modules/) from the
  # snapshot, or else from the main clone. COW clones, mtimes preserved. Without
  # node_modules e.g. `npm run dev` can't find local bins like vite.
  local src_dir="${snap:-$main_clone}" d
  local -a copied
  for d in "${_WS_ARTIFACT_DIRS[@]}"; do [[ -d "$src_dir/$d" ]] && copied+=("$d/"); done
  if (( ${#copied} )); then
    _ws_step copy "$repo: build dirs ${copied[*]} from $([[ -n "$snap" ]] && echo "the snapshot" || echo "the main clone") $(_ws_tilde "$src_dir")"
    for d in "${_WS_ARTIFACT_DIRS[@]}"; do
      [[ -d "$src_dir/$d" ]] && _ws_copy "$src_dir/$d" "$dest/$d"
    done
  fi

  # git worktree add stamps EVERY checked-out file with the current time, which
  # breaks Elixir's incremental build. On `mix compile`, Mix compares the mtime
  # of mix.exs and config/*.exs against what the copied manifest recorded; if
  # any are newer it concludes "config changed" and forces a FULL recompile —
  # the digest fallback that protects ordinary source files does NOT apply to
  # this config-staleness check, so the relocated _build is thrown away. So put
  # back the mtimes the build was made against: recorded in the snapshot, or
  # read off the main clone. Only for files whose content matches the build's
  # commit — a file that differs (an existing branch, a stale main clone) keeps
  # "now" so it's seen as changed. (Repo-agnostic: it's just file mtimes.)
  if [[ -n "$snap" ]]; then
    _ws_step mtimes "$repo: source file mtimes as recorded in the snapshot"
    _ws_mtimes restore "$dest" "$snap_sha" --from-file "$snap/mtimes" | _ws_indent
  else
    _ws_step mtimes "$repo: source file mtimes from the main clone $(_ws_tilde "$main_clone")"
    _ws_mtimes restore "$dest" "$(git -C "$main_clone" rev-parse HEAD)" --from-dir "$main_clone" | _ws_indent
  fi

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
  local -a linked
  local envrc_note=""
  if [[ -e "$main_clone/.env" && ! -e "$dest/.env" ]]; then
    ln -sf "$main_clone/.env" "$dest/.env"
    linked+=(.env)
  fi
  if [[ -e "$dest/.envrc" ]]; then
    # The repo tracks its own .envrc (e.g. one that self-derives per-worktree
    # isolation) — nothing to symlink, just authorise it for direnv.
    direnv allow "$dest" 2>/dev/null || true
    envrc_note="authorised the repo's tracked .envrc"
  # Skip the .envrc symlink when the repo has a .ws-init hook — that hook
  # generates its own per-worktree .envrc, so there's nothing to symlink (and
  # writing over a symlink would clobber the main clone's file).
  elif [[ -f "$main_clone/.envrc" && ! -x "$main_clone/.ws-init" ]]; then
    ln -sf "$main_clone/.envrc" "$dest/.envrc"
    direnv allow "$dest"
    linked+=(.envrc)
  fi
  if [[ -f "$main_clone/.mcp.json" && ! -e "$dest/.mcp.json" ]]; then
    ln -sf "$main_clone/.mcp.json" "$dest/.mcp.json"
    linked+=(.mcp.json)
  fi
  if [[ -f "$main_clone/.claude/settings.local.json" && ! -e "$dest/.claude/settings.local.json" ]]; then
    mkdir -p "$dest/.claude"
    ln -sf "$main_clone/.claude/settings.local.json" "$dest/.claude/settings.local.json"
    linked+=(.claude/settings.local.json)
  fi
  if [[ -f "$main_clone/CLAUDE.local.md" && ! -e "$dest/CLAUDE.local.md" ]]; then
    ln -sf "$main_clone/CLAUDE.local.md" "$dest/CLAUDE.local.md"
    linked+=(CLAUDE.local.md)
  fi
  if (( ${#linked} )) || [[ -n "$envrc_note" ]]; then
    _ws_step links "$repo: env files"
    (( ${#linked} )) && _ws_detail "symlinked from the main clone: ${linked[*]}"
    [[ -n "$envrc_note" ]] && _ws_detail "$envrc_note"
  fi

  # The `post` phase of the same .ws-init hook (see the `pre` invocation above).
  # Runs with the fully set-up worktree as cwd, so a repo can wire up its
  # per-workspace state (ports, DB, env, …) without the workspace layer knowing
  # anything project-specific. cwd == WS_DEST here.
  if [[ -x "$main_clone/.ws-init" ]]; then
    _ws_hook_header ".ws-init post" "$main_clone/.ws-init" "(in $(_ws_tilde "$dest"))"
    _ws_nested _ws_init_run post "$dest" "$main_clone" "$dest" "$branch" "$snap_sha" \
      || _ws_warn ".ws-init post exited non-zero for $repo — the worktree is created; check the output above"
  fi
}

# _ws_create <repo|path> <branch> [--bg|--no-window] — create a workspace from
# a repo + branch. Repo-agnostic (the branch is based off origin's default by
# _ws_setup_worktree, so the clone needn't be on master). Runs the user's
# `pre-create` hook first and the `created` hook at the end; with --bg the
# `created` hook is told not to switch to it (WS_BG=1); with --no-window
# neither hook runs (for headless scratch workspaces no human will ever type
# into — an idle window on one just looks like abandoned work).
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

  _ws_step_top create "workspace '$short' (branch '$branch') from $repo"
  # A leftover empty dir (e.g. from a previously aborted create) shouldn't block
  # us — only refuse if the workspace actually has contents.
  if [[ -d "$workspace" && -n "$(ls -A "$workspace" 2>/dev/null)" ]]; then
    _ws_fail "Workspace already exists (and is not empty): $workspace"
    return 1
  fi
  local hook_rc
  if [[ -z "$no_window" ]]; then
    _ws_hook_shown pre-create WS_NAME="$short" WS_DIR="$workspace" WS_ROOT_DIR="$workspace" WS_BRANCH="$branch"
    hook_rc=$?
    if (( hook_rc != 0 && hook_rc != 127 )); then
      _ws_fail "pre-create hook refused workspace '$short' (rc $hook_rc)"
      return 1
    fi
  fi

  mkdir -p "$workspace"
  # rmdir only removes it if still empty, so an aborted setup leaves no stub.
  _ws_setup_worktree "$main_clone" "$branch" "$workspace/$repo" || { rmdir "$workspace" 2>/dev/null; return 1; }

  # Present the workspace (open a window, …) — the user's `created` hook.
  # --bg asks it not to switch focus; --no-window skips it entirely (headless
  # scratch workspaces no human will type into).
  if [[ -z "$no_window" ]]; then
    _ws_hook_shown created WS_NAME="$short" WS_DIR="$workspace/$repo" WS_ROOT_DIR="$workspace" WS_BRANCH="$branch" ${bg:+WS_BG=1}
    hook_rc=$?
    (( hook_rc == 0 || hook_rc == 127 )) || _ws_warn "created hook failed for '$short' (rc $hook_rc)"
  fi

  _ws_step done "workspace '$short' ready"
  _ws_ok "$(_ws_tilde "$workspace") — '$repo' on branch '$branch'"
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

    _ws_step_top add "$repo → workspace '${workspace:t}' (branch '$branch')"
    if [[ ! -e "$main_clone/.git" ]]; then
      _ws_fail "No git repo at $main_clone — skipping '$arg'"
      continue
    fi
    if [[ -d "$workspace/$repo" ]]; then
      _ws_fail "Repo '$repo' already in workspace — skipping"
      continue
    fi
    if _ws_setup_worktree "$main_clone" "$branch" "$workspace/$repo"; then
      _ws_step done "added '$repo'"
      _ws_ok "$(_ws_tilde "$workspace/$repo") — on branch '$branch'"
      _WS_LAST_ADDED="$workspace/$repo"
    else
      _ws_step done "adding '$repo' failed"
      _ws_fail "Failed to add '$repo'"
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

# _ws_switch_workspace <workspace-dir> — run the user's `switch` hook with
# WS_DIR wherever the members' `switch` .ws-init phases point (workspace root
# if none do).
_ws_switch_workspace() {
  local workspace="$1"
  [[ -z "$workspace" ]] && { echo_failure "Usage: _ws_switch_workspace <dir>"; return 1; }
  local short=$(basename "$workspace") hook_rc
  _ws_hook switch WS_NAME="$short" WS_DIR="$(_ws_switch_dir "$workspace")" WS_ROOT_DIR="$workspace" WS_BRANCH="$(_ws_branch "$workspace" 2>/dev/null)"
  hook_rc=$?
  (( hook_rc == 0 || hook_rc == 127 )) || echo_warn "switch hook failed for '$short' (rc $hook_rc)"
}

# _ws_switch_worktree <repo-dir> — run the user's `switch` hook with WS_DIR =
# the chosen repo's worktree.
_ws_switch_worktree() {
  local repodir="$1"
  [[ -z "$repodir" ]] && { echo_failure "Usage: _ws_switch_worktree <repo-dir>"; return 1; }
  local workspace=$(dirname "$repodir")
  local short=$(basename "$workspace") hook_rc
  _ws_hook switch WS_NAME="$short" WS_DIR="$repodir" WS_ROOT_DIR="$workspace" WS_BRANCH="$(_ws_branch "$workspace" 2>/dev/null)"
  hook_rc=$?
  (( hook_rc == 0 || hook_rc == 127 )) || echo_warn "switch hook failed for '$short' (rc $hook_rc)"
}

# _ws_delete <workspace-dir> — run each member repo's .ws-init `delete` hook,
# remove every member worktree (the branches stay in git), then rm the
# workspace dir and run the user's `deleted` hook.
_ws_delete() {
  local workspace="$1" force=""
  [[ "${2:-}" == "--force" ]] && force=1
  [[ -z "$workspace" ]] && { echo_failure "Usage: _ws_delete <workspace-dir> [--force]"; return 1; }

  # Safety: only ever operate under WS_ROOT (as given, or symlink-resolved —
  # _ws_from_pwd hands back the physical path).
  local root_p=$(cd -q "$WS_ROOT" 2>/dev/null && pwd -P)
  case "$workspace" in
    "$WS_ROOT"/*|"${root_p:-$WS_ROOT}"/*) ;;
    *) echo_failure "Refusing: '$workspace' is not under $WS_ROOT"; return 1 ;;
  esac
  if [[ ! -d "$workspace" ]]; then
    echo_failure "No such workspace: $workspace"
    return 1
  fi

  local short=$(basename "$workspace")
  local branch=$(_ws_branch "$workspace" 2>/dev/null)   # before the worktrees go
  local hook_rc

  _ws_step_top delete "workspace '$short'${force:+ (--force)}"
  # The user's pre-delete hook may refuse (rc 1 — e.g. open PRs whose branch
  # lives only in this worktree). Unknown (other non-zero) warns and proceeds;
  # --force skips the hook entirely.
  if [[ -z "$force" ]]; then
    _ws_hook_shown pre-delete WS_NAME="$short" WS_DIR="$workspace" WS_ROOT_DIR="$workspace" WS_BRANCH="$branch"
    hook_rc=$?
    if (( hook_rc == 1 )); then
      _ws_fail "Refusing to delete workspace $short (pre-delete hook said no; use --force to override)"
      return 1
    elif (( hook_rc != 0 && hook_rc != 127 )); then
      _ws_warn "pre-delete hook for $short returned $hook_rc (unknown) — proceeding"
    fi
  fi

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
      _ws_hook_header ".ws-init delete" "$main_worktree/.ws-init" "(in $(_ws_tilde "$member"))"
      _ws_nested _ws_init_run delete "$member" "$main_worktree" "$member" "$member_branch" \
        || _ws_warn ".ws-init delete failed for $member — continuing with deletion"
    fi

    _ws_step git "${member:t}: remove worktree $(_ws_tilde "$member") (branch kept)"
    git -C "$main_worktree" worktree remove --force "$member" 2>/dev/null
  done

  # Remove whatever remains of the workspace dir.
  [[ -d "$workspace" ]] && rm -rf "$workspace"

  _ws_step done "workspace '$short' deleted"
  _ws_ok "$(_ws_tilde "$workspace") removed (branches kept)"

  # LAST, always: the user's `deleted` hook (release leases, kill the window,
  # …). It may kill the very window this shell runs in, SIGHUPping us —
  # anything below it would silently not run. Its rc is reported but never
  # changes ours: the workspace IS gone.
  _ws_hook_shown deleted WS_NAME="$short" WS_DIR="$workspace" WS_ROOT_DIR="$workspace" WS_BRANCH="$branch"
  hook_rc=$?
  (( hook_rc == 0 || hook_rc == 127 )) || _ws_warn "deleted hook failed for '$short' (rc $hook_rc)"
  return 0
}

# wsc [--bg] <branch> — create a workspace from the repo in the current directory.
# Works whether you're in the repo's main clone or inside an existing worktree:
# it resolves the main clone (where the true source lives) and bases the new
# branch off origin's default, so you can spin up a fresh workspace from within
# another one without inheriting its branch. --bg tells the `created` hook not
# to switch to the new workspace.
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

# wsd [-f] [name|path ...] — delete one or more workspaces (defaults to the
# one you're standing in). Each is deleted independently: a refusal or failure
# on one doesn't stop the rest; the rc is the last failure's (0 if all went).
function wsd() {
  local workspace force="" arg
  local -a workspaces
  for arg in "$@"; do
    case "$arg" in
      --force|-f) force=1 ;;
      *)
        if [[ "$arg" == */* || "$arg" == "~"* ]]; then
          workspaces+=("${arg/#\~/$HOME}")
        else
          workspaces+=("$WS_ROOT/$arg")
        fi
        ;;
    esac
  done
  if (( ${#workspaces} == 0 )); then
    workspace=$(_ws_from_pwd)
    if [[ -z "$workspace" ]]; then
      echo_failure "Not inside a workspace; pass one or more: wsd [--force] <name>..."
      return 1
    fi
    workspaces=("$workspace")
  fi

  # If we're standing inside a workspace we're deleting, step out first —
  # and step back in if it survives (e.g. pre-delete refused), so WS_NAME
  # is restored and a bare `wsd -f` retries the same workspace.
  local cwd=$(pwd -P) back=$PWD
  local real
  for workspace in "${workspaces[@]}"; do
    real=${workspace:A}
    [[ "$cwd" == "$real" || "$cwd" == "$real"/* ]] && { cd "$WS_SRC_ROOT"; break; }
  done

  local rc=0 one_rc
  local -a failed
  for workspace in "${workspaces[@]}"; do
    _ws_delete "$workspace" ${force:+--force}
    one_rc=$?
    (( one_rc )) && { rc=$one_rc; failed+=("${workspace:t}"); }
  done

  [[ "$PWD" != "$back" && -d "$back" ]] && cd "$back"
  if (( ${#workspaces} > 1 && ${#failed} )); then
    echo_failure "${#failed} of ${#workspaces} workspace(s) not deleted: ${(j:, :)failed}"
  fi
  return $rc
}

# wsp [--yes] [--force] — purge inactive workspaces: delete every workspace
# the user's `active` hook does not list (with no hook, every workspace is a
# candidate — the per-workspace gates below still apply). Workspaces with
# uncommitted changes, or that the `pre-delete` hook refuses (e.g. open PRs),
# are skipped unless --force — committed work is safe either way (branches are
# kept), but dirt or an open PR's only-copy branch would be lost.
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

  # Which workspaces are still "open" is the user's `active` hook's call. If it
  # can't tell (tmux down, fresh boot…) every workspace would look inactive —
  # refuse rather than purge the world. No hook at all = no presentation layer
  # = everything is a candidate.
  local active hook_rc
  active=$(_ws_hook active); hook_rc=$?
  if (( hook_rc == 127 )); then
    active=""
  elif (( hook_rc != 0 )); then
    echo_failure "active hook failed (rc $hook_rc) — can't tell which workspaces are open. Refusing; use wsd for individual deletes."
    return 1
  fi

  local ws short repo dirty label
  local -a purge labels skipped skipped_hook
  for ws in "$WS_ROOT"/*(/N); do
    short=$(basename "$ws")
    print -r -- "$active" | grep -qxF "$short" && continue
    dirty=0
    for repo in "$ws"/*(/N); do
      [[ -e "$repo/.git" ]] || continue
      [[ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]] && dirty=1
    done
    # The pre-delete hook (open PRs, …) gates each candidate; quiet here, the
    # summary line below reports the skips. _ws_delete asks it again for the
    # ones actually deleted.
    local refused=0
    if [[ -z "$force" ]]; then
      _ws_hook pre-delete WS_NAME="$short" WS_DIR="$ws" WS_ROOT_DIR="$ws" WS_BRANCH="$(_ws_branch "$ws" 2>/dev/null)" >/dev/null 2>&1
      (( $? == 1 )) && refused=1
    fi
    if (( refused )); then
      skipped_hook+=("$short")
      continue
    fi
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
  (( ${#skipped_hook} )) && echo_warn "Skipping ${#skipped_hook} refused by the pre-delete hook (use --force to include): ${(j:, :)skipped_hook}"
  if (( ${#purge} == 0 )); then
    echo_success "Nothing to purge — every workspace is active."
    return 0
  fi

  _ws_step_top purge "inactive workspaces to delete (${#purge}):"
  for label in "${labels[@]}"; do _ws_detail "$label"; done
  if [[ -z "$yes" ]] && ! _ws_confirm "Delete these ${#purge} workspace(s)?"; then
    echo_failure "Aborted — nothing deleted."
    return 1
  fi

  # Step out first if we're standing inside one of the doomed workspaces.
  local cwd=$(pwd -P)
  for ws in "${purge[@]}"; do
    [[ "$cwd" == "$ws"* ]] && { cd "$WS_SRC_ROOT"; break; }
  done

  for ws in "${purge[@]}"; do
    _ws_delete "$ws" ${force:+--force}
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
  repos=("$WS_SRC_ROOT"/*(/N:t))
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

# WS_NAME=<workspace short name> is exported whenever the shell is inside a
# workspace (and unset when it leaves), so per-workspace tooling can find its
# identity without sniffing $PWD — the ports registry uses it as the default
# owner (ws:$WS_NAME) for every command when no owner is given.
_ws_export_name() {
  local ws=$(_ws_from_pwd)
  if [[ -n "$ws" ]]; then export WS_NAME="${ws:t}"; else unset WS_NAME; fi
}
autoload -Uz add-zsh-hook && add-zsh-hook chpwd _ws_export_name
_ws_export_name
