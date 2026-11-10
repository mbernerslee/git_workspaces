#!/usr/bin/env python3
"""Clone a directory tree in ONE clonefile(2) call (macOS / APFS).

  ws_clone.py <src-dir> <dest>     (dest must not exist)

`cp -Rc` clones file by file — ~8s for ploy-server's 38k-file _build. The
kernel can clone the whole hierarchy in a single call (~0.5s): copy-on-write,
mtimes and symlinks preserved. Exits non-zero if the call fails (different
volume, non-APFS, not macOS…) so the caller can fall back to cp.
"""
import ctypes
import os
import sys

if len(sys.argv) != 3:
    sys.exit(__doc__)
libc = ctypes.CDLL(None, use_errno=True)
clonefile = getattr(libc, "clonefile", None)
if clonefile is None:
    sys.exit("clonefile(2) not available")
CLONE_NOFOLLOW = 0x0001  # clone a symlink itself, never its target
if clonefile(os.fsencode(sys.argv[1]), os.fsencode(sys.argv[2]), ctypes.c_uint32(CLONE_NOFOLLOW)) != 0:
    sys.exit(f"clonefile: {os.strerror(ctypes.get_errno())}")
