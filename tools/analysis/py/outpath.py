#!/usr/bin/env python3
"""Resolve where a tool may write ROM-derived output (stdlib only).

usage: outpath.py PATH    print the resolved absolute path, or exit 1 with a message

Every output path in tools/analysis goes through this check: lib.sh's
mra_out_path (harness --out/--wav/--save, Ghidra project and seed directories,
ghidra_run.sh out=FILE and GHIDRA_LOG) and the Python helpers' output files.

- A relative PATH resolves under $MRA_OUT (default <repo>/analysis-out, gitignored).
- "..", "." and symlinks are resolved first, so the check sees where the file
  will really be written. The path does not need to exist yet.
- Inside the repository work tree, the path must be gitignored
  (git check-ignore). A path git would track is refused.
- Paths outside the repository are accepted.

MRA_REPO and MRA_OUT are read from the environment, with the same defaults as
lib.sh.
"""
import os
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))


def repo_root():
    return os.environ.get("MRA_REPO") or os.path.normpath(os.path.join(_HERE, "..", "..", ".."))


def out_root():
    return os.environ.get("MRA_OUT") or os.path.join(repo_root(), "analysis-out")


class TrackedPathError(Exception):
    pass


def _git_ok(*args):
    try:
        return subprocess.run(["git"] + list(args), stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL).returncode == 0
    except OSError:  # no git: nothing can be committed either
        return False


def resolve(path):
    """Absolute, symlink-free output path for PATH; raises TrackedPathError."""
    p = path if os.path.isabs(path) else os.path.join(out_root(), path)
    real = os.path.realpath(p)
    repo = os.path.realpath(repo_root())
    if real == repo or real.startswith(repo + os.sep):
        # "/x" makes the last component a directory, so a directory pattern such
        # as "analysis-out/" matches even before the directory exists.
        if (_git_ok("-C", repo, "rev-parse", "--is-inside-work-tree") and
                not _git_ok("-C", repo, "check-ignore", "-q", "--no-index", real + "/x")):
            raise TrackedPathError("refusing to write ROM-derived output to a tracked path: %s (use %s)"
                                   % (real, out_root()))
    return real


def out_file(path):
    """resolve() for a file the caller is about to write; creates its directory.
    Exits with a message instead of returning a refused path."""
    try:
        real = resolve(path)
    except TrackedPathError as e:
        sys.exit("%s: %s" % (os.path.basename(sys.argv[0]), e))
    os.makedirs(os.path.dirname(real), exist_ok=True)
    return real


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__.split("\n\n")[1])
    try:
        print(resolve(sys.argv[1]))
    except TrackedPathError as e:
        sys.exit(str(e))


if __name__ == "__main__":
    main()
