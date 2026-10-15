#!/usr/bin/env bash
# Tests for the user-hook contract of git_workspaces.zsh.
# Run: tests/ws_hooks_test.sh   (exit 1 on any failure)
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WSZSH="${WSZSH:-$here/../git_workspaces.zsh}"

T="$(mktemp -d "${TMPDIR:-/tmp}/ws-hooks-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export WS_ROOT="$T/workspaces" WS_SRC_ROOT="$T/src" WS_HOOKS_DIR="$T/hooks" WS_STATE="$T/tv-ws"
export HOOK_LOG="$T/hooks.log"
mkdir -p "$WS_ROOT" "$WS_SRC_ROOT" "$WS_HOOKS_DIR" "$T/bin"
export PATH="$T/bin:$PATH"
unset WS_NAME TMUX TMUX_PANE
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# Any stray tmux call is a failed boundary: the workspace layer must not know tmux.
cat >"$T/bin/tmux" <<'EOF'
#!/usr/bin/env bash
echo "TMUX CALLED: $*" >>"$HOOK_LOG"; exit 1
EOF
chmod +x "$T/bin/tmux"
# direnv is invoked by _ws_setup_worktree when an .envrc exists; stub it.
printf '#!/usr/bin/env bash\nexit 0\n' >"$T/bin/direnv"; chmod +x "$T/bin/direnv"

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2"; }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected: [$3] got: [$2]"; fi; }
assert_contains() { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1" "missing [$3] in: $2"; fi; }
assert_not_contains() { if grep -qF -- "$3" <<<"$2"; then bad "$1" "unexpected [$3] in: $2"; else ok "$1"; fi; }
assert_dir()      { if [ -d "$2" ]; then ok "$1"; else bad "$1" "no dir $2"; fi; }
assert_no_dir()   { if [ ! -e "$2" ]; then ok "$1"; else bad "$1" "$2 exists"; fi; }

# zws '<zsh code>' — run code with git_workspaces.zsh sourced. stdout+stderr in $OUT, rc in $RC.
zws() { OUT="$(zsh -c "source '$WSZSH' >/dev/null 2>&1; $1" 2>&1)"; RC=$?; }
# hook <name> [body] — install a fake hook that logs "<name> WS_NAME=… WS_DIR=… WS_ROOT_DIR=… WS_BRANCH=… WS_BG=… DIR_EXISTS=…"
# then runs the optional body (which decides the exit code).
hook() {
  cat >"$WS_HOOKS_DIR/$1" <<EOF
#!/usr/bin/env bash
echo "$1 WS_NAME=\${WS_NAME-} WS_DIR=\${WS_DIR-} WS_ROOT_DIR=\${WS_ROOT_DIR-} WS_BRANCH=\${WS_BRANCH-} WS_BG=\${WS_BG-} DIR_EXISTS=\$([ -d "\${WS_ROOT_DIR-/nonexistent}" ] && echo y || echo n)" >>"\$HOOK_LOG"
${2:-exit 0}
EOF
  chmod +x "$WS_HOOKS_DIR/$1"
}
unhook() { rm -f "$WS_HOOKS_DIR/$1"; }
hooks_fired() { awk '{print $1}' "$HOOK_LOG" | tr '\n' ' '; }
hook_line() { grep "^$1 " "$HOOK_LOG" | tail -1; }
reset_log() { : >"$HOOK_LOG"; }

# A main clone with an origin, so `git fetch origin` and the default-branch logic work.
mkrepo() {  # mkrepo <name>
  git init -q --bare -b master "$T/origin/$1.git"
  git clone -q "$T/origin/$1.git" "$WS_SRC_ROOT/$1" 2>/dev/null
  ( cd "$WS_SRC_ROOT/$1" && echo hi >README && git add README && git commit -qm init && git push -q origin master \
    && git remote set-head origin master )
}
mkrepo repo
mkrepo other

# Guard: never touch the real ~/src/workspaces. If the override isn't honoured,
# stop before creating anything.
zws 'echo "$WS_ROOT"'
if [ "$OUT" != "$WS_ROOT" ]; then
  echo "ABORT: git_workspaces.zsh ignores WS_ROOT (got '$OUT'); refusing to run against the real workspaces dir"
  exit 1
fi

echo "== create fires pre-create then created"
hook pre-create; hook created
reset_log
zws "_ws_create '$WS_SRC_ROOT/repo' feat"
assert_eq "create rc" "$RC" 0
assert_dir "worktree made" "$WS_ROOT/feat/repo"
assert_eq "hook order" "$(hooks_fired)" "pre-create created "
assert_contains "pre-create gets name/branch" "$(hook_line pre-create)" "WS_NAME=feat WS_DIR=$WS_ROOT/feat WS_ROOT_DIR=$WS_ROOT/feat WS_BRANCH=feat WS_BG="
assert_contains "pre-create runs before the dir exists" "$(hook_line pre-create)" "DIR_EXISTS=n"
assert_contains "created lands in the repo" "$(hook_line created)" "WS_NAME=feat WS_DIR=$WS_ROOT/feat/repo WS_ROOT_DIR=$WS_ROOT/feat WS_BRANCH=feat WS_BG="
assert_contains "created runs after the dir exists" "$(hook_line created)" "DIR_EXISTS=y"
assert_not_contains "no tmux from the workspace layer" "$(cat "$HOOK_LOG")" "TMUX CALLED"

echo "== --bg sets WS_BG; --no-window skips both hooks"
reset_log
zws "_ws_create '$WS_SRC_ROOT/repo' bgws --bg"
assert_contains "created sees WS_BG=1" "$(hook_line created)" "WS_BG=1"
reset_log
zws "_ws_create '$WS_SRC_ROOT/repo' nowin --no-window"
assert_eq "no-window rc" "$RC" 0
assert_eq "no hooks under --no-window" "$(hooks_fired)" ""
assert_dir "…but the worktree is made" "$WS_ROOT/nowin/repo"

echo "== pre-create refusing aborts creation"
hook pre-create 'echo "nope: $WS_NAME taken" >&2; exit 1'
reset_log
zws "_ws_create '$WS_SRC_ROOT/repo' refused"
assert_eq "refused rc" "$RC" 1
assert_contains "hook stderr shown" "$OUT" "nope: refused taken"
assert_no_dir "nothing created" "$WS_ROOT/refused"
assert_eq "created never fired" "$(hooks_fired)" "pre-create "
hook pre-create

echo "== missing hooks are skipped silently"
unhook pre-create; unhook created
reset_log
zws "_ws_create '$WS_SRC_ROOT/repo' nohooks"
assert_eq "create without hooks rc" "$RC" 0
assert_not_contains "no warning about missing hooks" "$OUT" "hook failed"
assert_not_contains "…nor a refusal" "$OUT" "hook refused"
hook pre-create; hook created

echo "== a hook that hits command-not-found is a failure, not a missing hook"
hook created 'exec no-such-command-zz "$WS_NAME"'
reset_log
zws "_ws_create '$WS_SRC_ROOT/repo' cnf"
assert_eq "create still succeeds" "$RC" 0
assert_contains "…but warns, with rc 126 not 127" "$OUT" "created hook failed for 'cnf' (rc 126)"
hook created

echo "== switch"
hook switch
reset_log
zws "_ws_switch_workspace '$WS_ROOT/feat'"
assert_eq "switch rc" "$RC" 0
assert_contains "switch to workspace lands at its root (no .ws-init switch)" "$(hook_line switch)" "WS_NAME=feat WS_DIR=$WS_ROOT/feat WS_ROOT_DIR=$WS_ROOT/feat WS_BRANCH=feat"
reset_log
zws "_ws_switch_worktree '$WS_ROOT/feat/repo'"
assert_contains "switch to worktree lands in the repo" "$(hook_line switch)" "WS_NAME=feat WS_DIR=$WS_ROOT/feat/repo WS_ROOT_DIR=$WS_ROOT/feat"
# .ws-init switch steers WS_DIR
mkdir -p "$WS_SRC_ROOT/repo/sub"; mkdir -p "$WS_ROOT/feat/repo/sub"
cat >"$WS_SRC_ROOT/repo/.ws-init" <<'EOF'
#!/usr/bin/env bash
[ "$1" = switch ] && echo "$WS_DEST/sub"
exit 0
EOF
chmod +x "$WS_SRC_ROOT/repo/.ws-init"
reset_log
zws "_ws_switch_workspace '$WS_ROOT/feat'"
assert_contains ".ws-init switch output becomes WS_DIR" "$(hook_line switch)" "WS_DIR=$WS_ROOT/feat/repo/sub"
rm -f "$WS_SRC_ROOT/repo/.ws-init"

echo "== delete: pre-delete gates, deleted runs last"
hook pre-delete; hook deleted
reset_log
zws "_ws_delete '$WS_ROOT/bgws'"
assert_eq "delete rc" "$RC" 0
assert_eq "delete hook order" "$(hooks_fired)" "pre-delete deleted "
assert_contains "pre-delete sees the root" "$(hook_line pre-delete)" "WS_NAME=bgws WS_DIR=$WS_ROOT/bgws WS_ROOT_DIR=$WS_ROOT/bgws WS_BRANCH=bgws"
assert_contains "pre-delete runs while the dir exists" "$(hook_line pre-delete)" "DIR_EXISTS=y"
assert_contains "deleted runs after the dir is gone" "$(hook_line deleted)" "WS_NAME=bgws WS_DIR=$WS_ROOT/bgws WS_ROOT_DIR=$WS_ROOT/bgws WS_BRANCH=bgws WS_BG= DIR_EXISTS=n"
assert_no_dir "workspace removed" "$WS_ROOT/bgws"

hook pre-delete 'echo "open PRs on $WS_NAME" >&2; exit 1'
reset_log
zws "_ws_delete '$WS_ROOT/nowin'"
assert_eq "refused delete rc" "$RC" 1
assert_contains "refusal reason shown" "$OUT" "open PRs on nowin"
assert_dir "workspace kept" "$WS_ROOT/nowin/repo"
assert_eq "deleted not fired on refusal" "$(hooks_fired)" "pre-delete "

# wsd steps out of the workspace before deleting; on refusal it must step back
# in, so WS_NAME is still set and a bare `wsd -f` retries the same workspace.
zws "cd '$WS_ROOT/nowin/repo'; wsd; print -r -- \"PWD=\$PWD WS_NAME=\$WS_NAME\""
assert_eq "wsd refused rc" "$RC" 0
assert_contains "wsd refusal leaves you where you were" "$OUT" "PWD=$WS_ROOT/nowin/repo WS_NAME=nowin"

hook pre-delete 'exit 2'
reset_log
zws "_ws_delete '$WS_ROOT/nowin'"
assert_eq "unknown (rc 2) proceeds" "$RC" 0
assert_contains "…with a warning" "$OUT" "unknown"
assert_no_dir "workspace removed on unknown" "$WS_ROOT/nowin"

hook pre-delete 'exit 1'
reset_log
zws "_ws_delete '$WS_ROOT/nohooks' --force"
assert_eq "--force rc" "$RC" 0
assert_eq "--force skips pre-delete, still runs deleted" "$(hooks_fired)" "deleted "
hook pre-delete

echo "== deleted hook failure never changes wsd's result"
hook deleted 'exit 3'
zws "_ws_create '$WS_SRC_ROOT/repo' delfail --no-window"
reset_log
zws "_ws_delete '$WS_ROOT/delfail'"
assert_eq "rc 0 despite failing deleted hook" "$RC" 0
assert_no_dir "…and the workspace is gone" "$WS_ROOT/delfail"
hook deleted

echo "== wsd other from inside workspace A hands hooks WS_NAME=other"
zws "_ws_create '$WS_SRC_ROOT/repo' aaa --no-window"
zws "_ws_create '$WS_SRC_ROOT/repo' bbb --no-window"
reset_log
zws "cd '$WS_ROOT/aaa/repo'; [ \"\$WS_NAME\" = aaa ] || echo 'shell WS_NAME not aaa'; wsd bbb"
assert_eq "wsd rc" "$RC" 0
assert_not_contains "shell had WS_NAME=aaa" "$OUT" "shell WS_NAME not aaa"
assert_contains "hook got the deleted workspace's name, not the shell's" "$(hook_line deleted)" "WS_NAME=bbb "
assert_no_dir "bbb removed" "$WS_ROOT/bbb"
assert_dir "aaa untouched" "$WS_ROOT/aaa/repo"

echo "== wsp: active hook decides candidates"
hook active 'exit 1'
reset_log
zws "wsp --yes"
assert_eq "failing active refuses" "$RC" 1
assert_contains "…and says so" "$OUT" "Refusing"
assert_dir "nothing purged" "$WS_ROOT/aaa/repo"

zws "_ws_create '$WS_SRC_ROOT/repo' ccc --no-window"
hook active 'echo aaa'
reset_log
zws "wsp --yes"
assert_eq "wsp rc" "$RC" 0
assert_dir "active workspace kept" "$WS_ROOT/aaa/repo"
assert_no_dir "inactive purged" "$WS_ROOT/ccc"
assert_contains "purge ran pre-delete for the candidate" "$(cat "$HOOK_LOG")" "pre-delete WS_NAME=ccc "
assert_contains "…and deleted" "$(cat "$HOOK_LOG")" "deleted WS_NAME=ccc "
assert_not_contains "…but never touched the active one" "$(cat "$HOOK_LOG")" "WS_NAME=aaa "

zws "_ws_create '$WS_SRC_ROOT/repo' ddd --no-window"
hook pre-delete '[ "$WS_NAME" = ddd ] && exit 1; exit 0'
reset_log
zws "wsp --yes"
assert_dir "pre-delete refusal skips it in purge" "$WS_ROOT/ddd/repo"
assert_contains "…reported as skipped" "$OUT" "ddd"
reset_log
zws "wsp --yes --force"
assert_no_dir "--force purges it anyway" "$WS_ROOT/ddd"
hook pre-delete

unhook active
zws "_ws_create '$WS_SRC_ROOT/repo' eee --no-window"
reset_log
zws "wsp --yes"
assert_no_dir "no active hook: every workspace is a candidate" "$WS_ROOT/eee"
assert_no_dir "…including aaa" "$WS_ROOT/aaa"

echo "== wsp keeps its dirty-tree guard"
zws "_ws_create '$WS_SRC_ROOT/repo' dirty --no-window"
echo change >>"$WS_ROOT/dirty/repo/README"
zws "wsp --yes"
assert_dir "dirty workspace skipped" "$WS_ROOT/dirty/repo"
zws "wsp --yes --force"
assert_no_dir "…unless --force" "$WS_ROOT/dirty"

echo "== WS_NAME chpwd export (moved from ports_test.sh)"
zws "_ws_create '$WS_SRC_ROOT/repo' myws --no-window"
mkdir -p "$T/elsewhere"
assert_eq "set on source when already inside" "$(cd "$WS_ROOT/myws/repo" && zsh -c "source '$WSZSH' >/dev/null 2>&1; echo \$WS_NAME")" "myws"
zws "cd '$WS_ROOT/myws/repo'; echo \$WS_NAME"; assert_eq "set on cd in" "$OUT" "myws"
zws "cd '$WS_ROOT/myws'; cd '$T/elsewhere'; echo \${WS_NAME-unset}"; assert_eq "unset on cd out" "$OUT" "unset"
zws "cd '$T/elsewhere'; echo \${WS_NAME-unset}"; assert_eq "not set outside" "$OUT" "unset"
: >"$T/chpwd.log"
zws "cd '$WS_ROOT/myws/repo'; _n() { echo x >>'$T/chpwd.log'; }; add-zsh-hook chpwd _n; _ws_from_pwd >/dev/null; _ws_export_name"
assert_eq "_ws_from_pwd / _ws_export_name trigger no chpwd hooks" "$(wc -l <"$T/chpwd.log" | tr -d ' ')" "0"

echo "== WS_SRC_ROOT / WS_STATE"
zws "_ws_resolve_main_clone other"; assert_eq "bare name → \$WS_SRC_ROOT/<name>" "$OUT" "$WS_SRC_ROOT/other"
zws "cd '$WS_ROOT/myws/repo'; tv() { :; }; wt; cat \"\$WS_STATE\""
assert_eq "wt writes the workspace to WS_STATE" "$OUT" "$WS_ROOT/myws"
zws "echo \$WS_STATE"; assert_eq "WS_STATE honours the override" "$OUT" "$T/tv-ws"
zws "env | grep -c '^WS_STATE='"; assert_eq "WS_STATE is exported" "$OUT" "1"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
