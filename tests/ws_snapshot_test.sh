#!/usr/bin/env bash
# Tests for build snapshots (ws-snapshot.sh / _ws_snapshot) and for new
# worktrees starting from them, plus the main-clone fallback's mtime restore.
# Run: tests/ws_snapshot_test.sh   (exit 1 on any failure)
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WSZSH="${WSZSH:-$here/../git_workspaces.zsh}"
SNAP="$here/../bin/ws-snapshot.sh"

# pwd -P: macOS $TMPDIR is a /var → /private/var symlink with a trailing slash.
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ws-snap-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$T"' EXIT
export WS_ROOT="$T/workspaces" WS_SRC_ROOT="$T/src" WS_HOOKS_DIR="$T/hooks" WS_STATE="$T/tv-ws"
export WS_SNAPSHOT_ROOT="$T/snapshots" WS_SNAPSHOT_KEEP=2
unset WS_SNAPSHOT_MAX_AGE WS_FRESH WS_NAME TMUX TMUX_PANE
export LOG="$T/hook.log" BUILD_FAIL="$T/build-fail"
mkdir -p "$WS_ROOT" "$WS_SRC_ROOT" "$WS_HOOKS_DIR" "$T/bin"
export PATH="$T/bin:$PATH"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
printf '#!/usr/bin/env bash\nexit 0\n' >"$T/bin/direnv"; chmod +x "$T/bin/direnv"

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2"; }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected: [$3] got: [$2]"; fi; }
assert_ne()       { if [ "$2" != "$3" ]; then ok "$1"; else bad "$1" "both: [$2]"; fi; }
assert_contains() { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1" "missing [$3] in: $2"; fi; }
assert_file()     { if [ -e "$2" ]; then ok "$1"; else bad "$1" "no $2"; fi; }
assert_no_file()  { if [ ! -e "$2" ]; then ok "$1"; else bad "$1" "$2 exists"; fi; }
zws() { OUT="$(zsh -c "source '$WSZSH' >/dev/null 2>&1; $1" 2>&1)"; RC=$?; }
snap() { OUT="$("$SNAP" "$@" 2>&1)"; RC=$?; }
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }
builds() { grep -c '^build ' "$LOG" 2>/dev/null || true; }

# An origin + main clone whose .ws-init "builds" by writing _build/out (a
# digest of the sources) and logs every phase with its context.
mkrepo() {  # mkrepo <name> [with-build]
  git init -q --bare -b master "$T/origin/$1.git"
  git clone -q "$T/origin/$1.git" "$WS_SRC_ROOT/$1" 2>/dev/null
  ( cd "$WS_SRC_ROOT/$1" && mkdir -p lib && echo one >lib/a.ex && echo two >lib/b.ex && echo cfg >mix.exs \
    && printf '_build/\ndeps/\n.ws-init\n' >.gitignore \
    && git add . && git commit -qm init && git push -q origin master && git remote set-head origin master )
  if [ "${2:-}" = with-build ]; then
    cat >"$WS_SRC_ROOT/$1/.ws-init" <<'EOF'
#!/usr/bin/env bash
echo "$1 PWD=$PWD WS_SNAPSHOT=${WS_SNAPSHOT-unset} HEAD=$(git rev-parse HEAD 2>/dev/null)" >>"$LOG"
echo "hello from the $1 hook"
ws_build() {
  [ -e "$BUILD_FAIL" ] && { echo "boom"; exit 3; }
  [ -e "$BUILD_FAIL.${WS_MAIN_CLONE##*/}" ] && { echo "boom"; exit 3; }
  mkdir -p _build deps
  # RENDEZVOUS: wait (up to 5s) for RENDEZVOUS_N builds to have started, then
  # record how many had — only parallel builds all see RENDEZVOUS_N.
  if [ -n "${RENDEZVOUS:-}" ]; then
    touch "$RENDEZVOUS/${WS_MAIN_CLONE##*/}"
    for _ in $(seq 50); do [ "$(ls "$RENDEZVOUS" | wc -l)" -ge "$RENDEZVOUS_N" ] && break; sleep 0.1; done
    ls "$RENDEZVOUS" | wc -l | tr -d ' ' >_build/met
  fi
  cat lib/*.ex >_build/out
  git rev-parse HEAD >_build/sha
  echo dep >deps/dep
}
phase="${1:-post}"
if declare -F "ws_${phase}" >/dev/null; then "ws_${phase}"; fi
EOF
  else
    printf '#!/usr/bin/env bash\necho "$1 WS_SNAPSHOT=${WS_SNAPSHOT-unset}" >>"$LOG"\n' >"$WS_SRC_ROOT/$1/.ws-init"
  fi
  chmod +x "$WS_SRC_ROOT/$1/.ws-init"
}
push_change() {  # push_change <repo> <file> <content> — a commit on origin, via another clone
  local c="$T/pusher-$1"
  [ -d "$c" ] || git clone -q "$T/origin/$1.git" "$c" 2>/dev/null
  ( cd "$c" && git pull -q && echo "$3" >"$2" && git add . && git commit -qm "change $2" && git push -q origin master )
}
origin_sha() { git -C "$T/origin/$1.git" rev-parse master; }

mkrepo app with-build
mkrepo plain
main="$WS_SRC_ROOT/app"
S="$WS_SNAPSHOT_ROOT/app"

echo "== _ws_copy clones a tree: contents, mtimes, relative symlinks"
mkdir -p "$T/cp/src/sub" && echo x >"$T/cp/src/sub/f" && ln -s sub/f "$T/cp/src/link"
touch -t 202001010000 "$T/cp/src/sub/f"
zws "_ws_copy '$T/cp/src' '$T/cp/dst'"
assert_eq "rc" "$RC" 0
assert_eq "content" "$(cat "$T/cp/dst/sub/f")" "x"
assert_eq "mtime kept" "$(mtime "$T/cp/dst/sub/f")" "$(mtime "$T/cp/src/sub/f")"
assert_eq "symlink kept as a link" "$(readlink "$T/cp/dst/link")" "sub/f"
mkdir -p "$T/cp/existing"
zws "_ws_copy '$T/cp/src' '$T/cp/existing'"
assert_eq "existing dest: cp semantics (copied inside)" "$(cat "$T/cp/existing/src/sub/f")" "x"

echo "== a repo without a build phase can't be snapshotted; --all skips it"
snap plain
assert_eq "plain rc" "$RC" 1
assert_contains "says why" "$OUT" "no build phase"
: >"$LOG"
snap --all
assert_eq "--all rc" "$RC" 0
assert_no_file "no plain snapshots" "$WS_SNAPSHOT_ROOT/plain"

echo "== the first snapshot (made by --all above)"
sha1="$(origin_sha app)"
assert_file "snapshot dir for origin's commit" "$S/$sha1/commit"
assert_eq "latest points at it" "$(cd "$S/latest" && pwd -P)" "$S/$sha1"
assert_eq "built output is in the snapshot" "$(cat "$S/$sha1/_build/out")" "$(printf 'one\ntwo')"
assert_file "deps in the snapshot" "$S/$sha1/deps/dep"
assert_file "mtimes recorded" "$S/$sha1/mtimes"
assert_file "checked stamp" "$S/checked"
assert_contains "build ran in the checkout" "$(grep '^build ' "$LOG")" "PWD=$S/checkout"
assert_contains "build got WS_SNAPSHOT=sha" "$(grep '^build ' "$LOG")" "WS_SNAPSHOT=$sha1"
assert_eq "main clone has no build output" "$(ls "$main/_build" 2>/dev/null)" ""
assert_no_file "lock released" "$S/lock"

echo "== re-running with origin unchanged builds nothing"
n="$(builds)"
snap app
assert_eq "rc" "$RC" 0
assert_contains "reports current" "$OUT" "is current"
assert_eq "no new build" "$(builds)" "$n"

echo "== a new workspace starts from the snapshot"
push_change app lib/a.ex ONE   # origin moves on; the snapshot is now behind
: >"$LOG"
co_mtime="$(mtime "$S/checkout/lib/b.ex")"
zws "_ws_create app feat --no-window"
assert_eq "create rc" "$RC" 0
w="$WS_ROOT/feat/app"
assert_eq "branch based on the snapshot's commit, not origin's" "$(git -C "$w" rev-parse HEAD)" "$sha1"
assert_contains "says it's behind" "$OUT" "1 commit(s) behind"
assert_eq "_build copied from the snapshot" "$(cat "$w/_build/sha")" "$sha1"
assert_file "deps copied from the snapshot" "$w/deps/dep"
assert_contains "pre told WS_SNAPSHOT" "$(grep '^pre ' "$LOG")" "WS_SNAPSHOT=$sha1"
assert_eq "source mtime = the checkout's at build time" "$(mtime "$w/lib/b.ex")" "$co_mtime"
assert_eq "mix.exs mtime restored too" "$(mtime "$w/mix.exs")" "$(mtime "$S/checkout/mix.exs")"

echo "== output says who is talking: [ws:…] = this library, [hook:…] = a hook"
plain="$(sed $'s/\x1b\\[[0-9;]*m//g' <<<"$OUT")"
assert_contains "first header names the library" "$(head -1 <<<"$plain")" "[ws:create] workspace 'feat'"
assert_contains "first header shows where the library lives" "$(head -1 <<<"$plain")" "(git_workspaces: "
assert_contains "snapshot step" "$plain" "[ws:snapshot] app: using snapshot ${sha1:0:12}"
assert_contains "hook header names the file that runs" "$plain" "[hook:.ws-init pre] $main/.ws-init"
assert_contains "hook output is nested" "$plain" "  │ hello from the pre hook"
assert_contains "git output is nested" "$plain" "  │ Preparing worktree"
after_pre="$(grep -A1 '│ hello from the pre hook' <<<"$plain" | tail -1)"
assert_contains "back to the library after the hook" "$after_pre" "[ws:git]"
assert_contains "post hook header" "$plain" "[hook:.ws-init post] $main/.ws-init"
assert_contains "done step" "$(tail -2 <<<"$plain")" "[ws:done] workspace 'feat' ready"
n_untagged="$(grep -cvE '^(\[(ws|hook):|  )' <<<"$plain")"
assert_eq "every line is a [tag] header or an indented detail" "$n_untagged" "0"

echo "== the next snapshot run picks up origin's new commit"
snap app
sha2="$(origin_sha app)"
assert_eq "rc" "$RC" 0
assert_eq "latest moved" "$(cd "$S/latest" && pwd -P)" "$S/$sha2"
assert_eq "rebuilt from the new sources" "$(head -1 "$S/$sha2/_build/out")" "ONE"
assert_file "previous snapshot kept (KEEP=2)" "$S/$sha1/commit"

echo "== an existing branch that changed a file: that file keeps a fresh mtime"
git -C "$main" branch -q old "$sha1"
git -C "$main" worktree add -q "$T/tmpwt" old && ( cd "$T/tmpwt" && echo CHANGED >lib/b.ex && git commit -qam change ) \
  && git -C "$main" worktree remove --force "$T/tmpwt"
before="$(date +%s)"
zws "_ws_create app old --no-window <<<y"
w="$WS_ROOT/old/app"
assert_eq "create rc" "$RC" 0
if [ "$(mtime "$w/lib/b.ex")" -ge "$before" ]; then ok "changed file not back-dated"; else bad "changed file not back-dated" "mtime $(mtime "$w/lib/b.ex") < $before"; fi
assert_eq "unchanged file restored" "$(mtime "$w/mix.exs")" "$(mtime "$S/checkout/mix.exs")"

echo "== WS_FRESH=1 ignores the snapshot (old behaviour: main clone)"
mkdir -p "$main/_build" && echo main-build >"$main/_build/sha"
touch -t 202001010000 "$main/lib/b.ex"
: >"$LOG"
zws "WS_FRESH=1 _ws_create app fresh --no-window"
w="$WS_ROOT/fresh/app"
assert_eq "create rc" "$RC" 0
assert_eq "_build from the main clone" "$(cat "$w/_build/sha")" "main-build"
assert_contains "pre got an empty WS_SNAPSHOT" "$(grep '^pre ' "$LOG")" "WS_SNAPSHOT= "
assert_eq "based on local master" "$(git -C "$w" rev-parse HEAD)" "$(git -C "$main" rev-parse master)"
assert_eq "mtimes copied from the main clone" "$(mtime "$w/lib/b.ex")" "$(mtime "$main/lib/b.ex")"

echo "== a snapshot not confirmed against origin recently isn't used"
echo 0 >"$S/checked"
zws "_ws_create app stale --no-window"
assert_eq "create rc" "$RC" 0
assert_eq "fell back to the main clone" "$(cat "$WS_ROOT/stale/app/_build/sha")" "main-build"
zws "_ws_snapshot_status '$main'"
assert_contains "status says not in use" "$OUT" "in use:   NO"

echo "== a failing build keeps the previous snapshot"
push_change app lib/b.ex TWO
touch "$BUILD_FAIL"
snap app
assert_eq "rc non-zero" "$RC" 1
assert_contains "says it failed" "$OUT" "failed"
assert_eq "latest unchanged" "$(cd "$S/latest" && pwd -P)" "$S/$sha2"
assert_file "last-error recorded" "$S/last-error"
assert_contains "build.log has the output" "$(cat "$S/build.log")" "boom"
zws "_ws_snapshot_status '$main'"
assert_contains "status shows FAILING" "$OUT" "FAILING"
rm -f "$BUILD_FAIL"

echo "== recovery, and pruning to WS_SNAPSHOT_KEEP"
snap app
sha3="$(origin_sha app)"
assert_eq "rc" "$RC" 0
assert_no_file "last-error cleared" "$S/last-error"
assert_eq "latest" "$(cd "$S/latest" && pwd -P)" "$S/$sha3"
assert_file "previous kept" "$S/$sha2/commit"
assert_no_file "oldest pruned" "$S/$sha1"
assert_eq "checkout survives pruning" "$(git -C "$S/checkout" rev-parse HEAD)" "$sha3"

echo "== a live lock makes a run skip; a dead one is cleared"
mkdir "$S/lock"; echo $$ >"$S/lock/pid"
snap app --force
assert_contains "skips while held" "$OUT" "already being made"
echo 999999 >"$S/lock/pid"
n="$(builds)"
snap app --force
assert_contains "clears a stale lock" "$OUT" "stale snapshot lock"
assert_eq "and builds" "$(builds)" "$((n + 1))"
assert_no_file "lock released" "$S/lock"

echo "== rm removes snapshots and the checkout worktree"
snap rm app
assert_no_file "snapshot dir gone" "$S"
assert_eq "worktree unregistered" "$(git -C "$main" worktree list | grep -c snapshots)" "0"

echo "== --all snapshots several repos in parallel; output stays in per-repo blocks"
mkrepo app2 with-build
mkrepo app3 with-build
export RENDEZVOUS="$T/rendezvous" RENDEZVOUS_N=3
mkdir -p "$RENDEZVOUS"
snap --all
unset RENDEZVOUS RENDEZVOUS_N
assert_eq "rc" "$RC" 0
for r in app app2 app3; do
  assert_eq "$r: snapshot made" "$(cat "$WS_SNAPSHOT_ROOT/$r/latest/_build/sha" 2>/dev/null)" "$(origin_sha $r)"
  assert_eq "$r: built alongside the others" "$(cat "$WS_SNAPSHOT_ROOT/$r/latest/_build/met" 2>/dev/null)" "3"
done
plain="$(sed $'s/\x1b\\[[0-9;]*m//g' <<<"$OUT")"
order="$(sed -nE 's/^\[ws:snapshot\] (app[0-9]*)[: ].*/\1/p' <<<"$plain" | uniq | tr '\n' ' ')"
assert_eq "blocks contiguous, in the order given" "$order" "app app2 app3 "
assert_eq "no stray temp dirs" "$(ls "${TMPDIR:-/tmp}" | grep -c "^ws-snapshot\.")" "0"

echo "== build duration recorded and shown"
assert_contains "took= in the commit file" "$(cat "$WS_SNAPSHOT_ROOT/app2/latest/commit")" "took="
zws "_ws_snapshot_status '$WS_SRC_ROOT/app2'"
assert_contains "status shows it" "$OUT" "(build took "

echo "== one repo failing in a parallel run doesn't stop the others"
push_change app2 lib/a.ex X2
push_change app3 lib/a.ex X3
touch "$BUILD_FAIL.app2"
snap --all
rm -f "$BUILD_FAIL.app2"
assert_eq "rc non-zero" "$RC" 1
assert_ne "app2 kept its old snapshot" "$(cat "$WS_SNAPSHOT_ROOT/app2/latest/_build/sha")" "$(origin_sha app2)"
assert_eq "app3 still snapshotted" "$(cat "$WS_SNAPSHOT_ROOT/app3/latest/_build/sha")" "$(origin_sha app3)"
assert_contains "the failure is reported" "$OUT" "app2"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
