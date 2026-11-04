#!/usr/bin/env bash
# Tests for the per-repo .ws-init protocol of git_workspaces.zsh (pre / post /
# switch / delete phases and the WS_DEST / WS_BRANCH / WS_MAIN_CLONE context).
# Run: tests/ws_init_test.sh   (exit 1 on any failure)
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WSZSH="${WSZSH:-$here/../git_workspaces.zsh}"

T="$(mktemp -d "${TMPDIR:-/tmp}/ws-init-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export WS_ROOT="$T/workspaces" WS_SRC_ROOT="$T/src" WS_HOOKS_DIR="$T/hooks" WS_STATE="$T/tv-ws"
export INIT_LOG="$T/init.log"
mkdir -p "$WS_ROOT" "$WS_SRC_ROOT" "$WS_HOOKS_DIR" "$T/bin"
export PATH="$T/bin:$PATH"
unset WS_NAME TMUX TMUX_PANE
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
printf '#!/usr/bin/env bash\nexit 0\n' >"$T/bin/direnv"; chmod +x "$T/bin/direnv"

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2"; }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected: [$3] got: [$2]"; fi; }
assert_contains() { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1" "missing [$3] in: $2"; fi; }
assert_dir()      { if [ -d "$2" ]; then ok "$1"; else bad "$1" "no dir $2"; fi; }
assert_no_dir()   { if [ ! -e "$2" ]; then ok "$1"; else bad "$1" "$2 exists"; fi; }
zws() { OUT="$(zsh -c "source '$WSZSH' >/dev/null 2>&1; $1" 2>&1)"; RC=$?; }
phase_line() { grep "^$1 " "$INIT_LOG" | tail -1; }
reset_log() { : >"$INIT_LOG"; }

mkrepo() {  # mkrepo <name>
  git init -q --bare -b master "$T/origin/$1.git"
  git clone -q "$T/origin/$1.git" "$WS_SRC_ROOT/$1" 2>/dev/null
  ( cd "$WS_SRC_ROOT/$1" && echo hi >README && git add README && git commit -qm init && git push -q origin master \
    && git remote set-head origin master )
}
mkrepo repo

zws 'echo "$WS_ROOT"'
[ "$OUT" = "$WS_ROOT" ] || { echo "ABORT: WS_ROOT override not honoured ('$OUT')"; exit 1; }

# The .ws-init under test: logs "<phase> WS_DEST=… WS_BRANCH=… WS_MAIN_CLONE=… PWD=… DEST_EXISTS=…"
# and lets the test choose pre's exit code / switch's output via files.
cat >"$WS_SRC_ROOT/repo/.ws-init" <<'EOF'
#!/usr/bin/env bash
echo "$1 WS_DEST=${WS_DEST-} WS_BRANCH=${WS_BRANCH-} WS_MAIN_CLONE=${WS_MAIN_CLONE-} PWD=$PWD DEST_EXISTS=$([ -d "${WS_DEST-/nonexistent}" ] && echo y || echo n)" >>"$INIT_LOG"
case "$1" in
  pre)    [ -e "$INIT_PRE_FAIL" ] && exit 1 ;;
  switch) [ -e "$INIT_SWITCH_DIR" ] && cat "$INIT_SWITCH_DIR" ;;
  delete) [ -e "$INIT_DELETE_FAIL" ] && exit 1 ;;
esac
exit 0
EOF
chmod +x "$WS_SRC_ROOT/repo/.ws-init"
export INIT_PRE_FAIL="$T/pre-fail" INIT_SWITCH_DIR="$T/switch-dir" INIT_DELETE_FAIL="$T/delete-fail"
main="$WS_SRC_ROOT/repo"

echo "== create runs pre (in the main clone, dest absent) then post (in the worktree)"
reset_log
zws "_ws_create '$main' feat --no-window"
assert_eq "create rc" "$RC" 0
assert_eq "phase order" "$(awk '{print $1}' "$INIT_LOG" | tr '\n' ' ')" "pre post "
assert_contains "pre context" "$(phase_line pre)" "WS_DEST=$WS_ROOT/feat/repo WS_BRANCH=feat WS_MAIN_CLONE=$main PWD=$main DEST_EXISTS=n"
assert_contains "post context" "$(phase_line post)" "WS_DEST=$WS_ROOT/feat/repo WS_BRANCH=feat WS_MAIN_CLONE=$main PWD=$WS_ROOT/feat/repo DEST_EXISTS=y"

echo "== a failing pre aborts, leaving no workspace dir"
: >"$INIT_PRE_FAIL"
reset_log
zws "_ws_create '$main' nope --no-window"
assert_eq "abort rc" "$RC" 1
assert_contains "…says why" "$OUT" ".ws-init pre failed"
assert_no_dir "no stub dir" "$WS_ROOT/nope"
assert_eq "post never ran" "$(awk '{print $1}' "$INIT_LOG" | tr '\n' ' ')" "pre "
rm -f "$INIT_PRE_FAIL"

echo "== an unreachable origin warns but still creates (GitHub down ≠ no workspace)"
reset_log
git -C "$main" remote set-url origin "$T/origin/nowhere.git"
zws "_ws_create '$main' offline --no-window"
git -C "$main" remote set-url origin "$T/origin/repo.git"
assert_eq "create rc despite failed fetch" "$RC" 0
assert_contains "…warns about it" "$OUT" "We couldn't fetch origin"
assert_dir "worktree made anyway" "$WS_ROOT/offline/repo"
assert_eq "both phases ran" "$(awk '{print $1}' "$INIT_LOG" | tr '\n' ' ')" "pre post "
zws "_ws_delete '$WS_ROOT/offline'"

echo "== wsa (_ws_add) runs the same phases for the added repo"
mkrepo other; cp "$main/.ws-init" "$WS_SRC_ROOT/other/.ws-init"
reset_log
zws "_ws_add '$WS_ROOT/feat' other"
assert_eq "add rc" "$RC" 0
assert_contains "pre for the added repo" "$(phase_line pre)" "WS_DEST=$WS_ROOT/feat/other WS_BRANCH=feat WS_MAIN_CLONE=$WS_SRC_ROOT/other"
assert_dir "added worktree" "$WS_ROOT/feat/other"

echo "== switch: the first member printing an existing dir wins"
mkdir -p "$WS_ROOT/feat/repo/deep"
echo "$WS_ROOT/feat/repo/deep" >"$INIT_SWITCH_DIR"
zws "_ws_switch_dir '$WS_ROOT/feat'"
assert_eq "switch dir honoured" "$OUT" "$WS_ROOT/feat/repo/deep"
echo "/nonexistent/dir" >"$INIT_SWITCH_DIR"
zws "_ws_switch_dir '$WS_ROOT/feat'"
assert_eq "a non-existent dir is ignored (falls back to the root)" "$OUT" "$WS_ROOT/feat"
rm -f "$INIT_SWITCH_DIR"
reset_log
zws "_ws_switch_dir '$WS_ROOT/feat' >/dev/null"
assert_contains "switch runs in the worktree" "$(phase_line switch)" "PWD=$WS_ROOT/feat/repo"

echo "== delete runs the delete phase in the worktree; a failing one never blocks"
: >"$INIT_DELETE_FAIL"
reset_log
zws "_ws_delete '$WS_ROOT/feat'"
assert_eq "delete rc" "$RC" 0
assert_contains "delete context" "$(grep '^delete ' "$INIT_LOG" | head -1)" "WS_DEST=$WS_ROOT/feat/"
assert_contains "…cwd is the worktree" "$(grep '^delete ' "$INIT_LOG" | head -1)" "DEST_EXISTS=y"
assert_eq "delete ran for both members" "$(grep -c '^delete ' "$INIT_LOG")" "2"
assert_contains "failure is a warning" "$OUT" ".ws-init delete failed"
assert_no_dir "workspace gone anyway" "$WS_ROOT/feat"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
