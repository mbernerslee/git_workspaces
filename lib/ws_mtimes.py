#!/usr/bin/env python3
"""Record / restore the modification times of a git checkout's tracked files.

Incremental build tools (Mix above all) decide what to rebuild from the mtimes
they recorded at compile time. A fresh `git worktree add` stamps every file with
"now", so a copied build looks stale. This puts the right mtimes back — in ONE
process (a `touch` per file costs ~2ms; ploy-server has ~18k files).

  ws_mtimes.py save    <worktree> <out-file>
      Write every tracked file's mtime (ns) to <out-file>.
  ws_mtimes.py restore <worktree> <base-sha> --from-file <file>
  ws_mtimes.py restore <worktree> <base-sha> --from-dir  <checkout>
      Give each tracked file of <worktree> the mtime recorded in <file> (or the
      mtime of the same path under <checkout>) — but ONLY for files whose content
      is the same as at <base-sha>, the commit the build was made from. A file
      that differs keeps its fresh "now" mtime so the build tool sees it as
      changed. (Restoring an old mtime onto changed content could hide the change:
      same size + same mtime and Mix skips the content check.) With --from-dir,
      files with uncommitted changes in <checkout> are skipped as well.

The record format is NUL-separated: path NUL mtime_ns NUL ... (paths may hold
any byte but NUL).
"""
import os
import subprocess
import sys


def git_z(cwd, *args):
    out = subprocess.run(["git", "-C", cwd, *args], check=True, capture_output=True).stdout
    return [p for p in out.split(b"\0") if p]


def tracked(worktree):
    return git_z(worktree, "ls-files", "-z")


def changed_since(worktree, base_sha):
    # Both sides of a rename count as changed, hence --no-renames.
    return set(git_z(worktree, "diff", "-z", "--no-renames", "--name-only", base_sha, "HEAD"))


def save(worktree, out_file):
    root = os.fsencode(worktree)
    parts = []
    for rel in tracked(worktree):
        try:
            st = os.lstat(os.path.join(root, rel))
        except OSError:
            continue
        parts += [rel, str(st.st_mtime_ns).encode()]
    tmp = out_file + ".tmp"
    with open(tmp, "wb") as f:
        f.write(b"\0".join(parts) + (b"\0" if parts else b""))
    os.replace(tmp, out_file)


def load(path):
    with open(path, "rb") as f:
        fields = f.read().split(b"\0")
    return {fields[i]: int(fields[i + 1]) for i in range(0, len(fields) - 1, 2)}


def restore(worktree, base_sha, mode, source):
    root = os.fsencode(worktree)
    skip = changed_since(worktree, base_sha)
    if mode == "--from-file":
        recorded = load(source)
        lookup = recorded.get
    else:
        src = os.fsencode(source)
        skip |= set(git_z(source, "diff", "-z", "--no-renames", "--name-only", "HEAD"))

        def lookup(rel):
            try:
                return os.lstat(os.path.join(src, rel)).st_mtime_ns
            except OSError:
                return None

    restored = 0
    for rel in tracked(worktree):
        if rel in skip:
            continue
        ns = lookup(rel)
        if ns is None:
            continue
        try:
            os.utime(os.path.join(root, rel), ns=(ns, ns), follow_symlinks=False)
            restored += 1
        except (OSError, NotImplementedError):
            pass
    print(f"{restored} restored, {len(skip)} changed since the build kept fresh")


def main(argv):
    if len(argv) == 3 and argv[0] == "save":
        save(argv[1], argv[2])
    elif len(argv) == 5 and argv[0] == "restore" and argv[3] in ("--from-file", "--from-dir"):
        restore(argv[1], argv[2], argv[3], argv[4])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
