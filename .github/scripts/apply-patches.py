#!/usr/bin/env python3
"""Apply the dash-OS4 patch series to a kernel/common tree.

Design note (user's call, 2026-10-29): the OS4 bring-up delta is kept as
**standard unified diffs** under `patches/<series>/` instead of scripted
string surgery, so the whole delta is reviewable in one place and the applier is
a dumb, uniform loop.

The trade-off is conflict handling: a patch has fixed context, so when the
upstream tree drifts the hunk fails instead of "doing something clever". That is
intentional — a failed apply aborts the build. The applier therefore:

  1. tries `git apply --check` (exact, no fuzz),
  2. falls back to `git apply --check --ignore-whitespace`,
  3. falls back to `patch -p1 --dry-run -F2`,
  4. if the *reverse* apply succeeds, the patch is already in the tree -> skip,
  5. otherwise fail loudly, printing the offending patch and the commands to
     inspect/regenerate it.

Usage:
  apply-patches.py --tree <kernel/common> --patches <dir> [--check]
                   [--strip 1] [-v]
"""

import argparse
import os
import subprocess
import sys


def sh(args, cwd=None, stdin_path=None):
    fh = open(stdin_path, "rb") if stdin_path else subprocess.DEVNULL
    try:
        p = subprocess.run(args, cwd=cwd, stdin=fh,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        return p.returncode, p.stdout.decode("utf-8", "replace")
    finally:
        if stdin_path:
            fh.close()


def is_git_tree(tree):
    rc, _ = sh(["git", "-C", tree, "rev-parse", "--is-inside-work-tree"])
    return rc == 0


def probe(tree, patch, strip, use_git):
    """Return (mode, detail) where mode is 'apply', 'already' or 'fail'."""
    if use_git:
        rc, out = sh(["git", "-C", tree, "apply", "--check", "-p%d" % strip, patch])
        if rc == 0:
            return "apply", "git apply"
        rc_ws, _ = sh(["git", "-C", tree, "apply", "--check", "--ignore-whitespace",
                       "-p%d" % strip, patch])
        if rc_ws == 0:
            return "apply", "git apply --ignore-whitespace"
        rc_rev, _ = sh(["git", "-C", tree, "apply", "--check", "--reverse",
                        "-p%d" % strip, patch])
        if rc_rev == 0:
            return "already", "git apply --reverse"
        git_err = out.strip()
    else:
        git_err = ""

    rc, out = sh(["patch", "-p%d" % strip, "--dry-run", "-F2", "-d", tree,
                  "--no-backup-if-mismatch", "-i", patch])
    if rc == 0:
        return "apply", "patch -p%d -F2" % strip
    rc_rev, _ = sh(["patch", "-p%d" % strip, "--dry-run", "-R", "-d", tree,
                    "-i", patch])
    if rc_rev == 0:
        return "already", "patch -R"
    return "fail", (git_err + "\n" + out).strip()


def apply_patch(tree, patch, strip, use_git, mode):
    if use_git and mode.startswith("git apply"):
        args = ["git", "-C", tree, "apply", "-p%d" % strip]
        if "ignore-whitespace" in mode:
            args.insert(4, "--ignore-whitespace")
        rc, out = sh(args + [patch])
    else:
        rc, out = sh(["patch", "-p%d" % strip, "-F2", "-d", tree,
                      "--no-backup-if-mismatch", "-i", patch])
    if rc != 0:
        raise SystemExit("apply failed after a successful dry-run (%s):\n%s\n%s"
                         % (mode, patch, out))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tree", required=True, help="kernel/common tree root")
    ap.add_argument("--patches", required=True, help="directory with *.patch")
    ap.add_argument("--strip", type=int, default=1)
    ap.add_argument("--check", action="store_true", help="dry-run only")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    tree = os.path.abspath(args.tree)
    if not os.path.isdir(tree):
        sys.exit("::error::%s is not a directory" % tree)

    # A series directory may contain *.patch directly or one level of
    # sub-directories (patches/<series>/*.patch), which is how this repo keeps
    # independent series (trusty-rescue, os4-vendor-hooks) side by side.
    root = os.path.abspath(args.patches)
    patches = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for f in sorted(filenames):
            if f.endswith(".patch"):
                patches.append(os.path.relpath(os.path.join(dirpath, f), root))
    patches.sort()
    if not patches:
        sys.exit("::error::no *.patch under %s" % root)

    use_git = is_git_tree(tree)
    print("apply-patches: %d patch(es) -> %s  (%s)"
          % (len(patches), tree, "git apply" if use_git else "patch"))

    failures = []
    for name in patches:
        path = os.path.join(root, name)
        mode, detail = probe(tree, path, args.strip, use_git)
        if mode == "already":
            print("  = %-52s already applied" % name)
            continue
        if mode == "fail":
            failures.append((name, detail))
            print("  ! %-52s FAILED" % name)
            continue
        if args.check:
            print("  o %-52s would apply (%s)" % (name, detail))
            continue
        apply_patch(tree, path, args.strip, use_git, detail)
        print("  + %-52s applied (%s)" % (name, detail))

    if failures:
        print()
        for name, detail in failures:
            print("::error::patch %s does not apply" % name)
            print("  hunk context no longer matches this tree. Inspect with:")
            print("    git -C %s apply --check -p%d -v %s"
                  % (tree, args.strip, os.path.join(root, name)))
            print("  then either rebase the patch onto the new base or re-derive")
            print("  the prototype/call-site from the stock kernel (see")
            print("  ~/下载/dash-os4/os4-hooks-callsite-map.md).")
            if args.verbose:
                print(detail)
            print()
        return 1

    print("apply-patches: done")
    return 0


if __name__ == "__main__":
    sys.exit(main())