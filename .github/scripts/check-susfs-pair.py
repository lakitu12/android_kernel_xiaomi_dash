#!/usr/bin/env python3
"""Static KSU <-> SUSFS pin pairing check, both directions, in seconds.

The two pins must move together, and both have drifted independently before:

  direction 1  SUSFS -> KSU
      A new susfs4ksu kernel patch starts calling a ksu_*() helper that the
      pinned KSU tree does not have. Example: 3f0b811 added
      ksu_install_su_fd() and the link died ~18 min in (run 34444400054).

  direction 2  KSU -> kernel-side SUSFS
      A new SukiSU builtin commit calls a susfs_*() helper / uses a supercall
      command that only a newer susfs4ksu provides. Example: builtin@b5917072
      calls susfs_parse_priority_app_strings() and
      susfs_set_priority_uid_filter() and uses CMD_SUSFS_SET_PRIORITY_UID_FILTER,
      all added by susfs4ksu c05208e "susfs: Add priority uid filter" - with the
      previous 8224c73 pin the build dies ~9 min in, in
      drivers/kernelsu/{policy/allowlist,manager/pkg_observer,supercall/dispatch}.c.

Run it after the SUSFS files are copied into the tree and the 50_ patch is
applied, i.e. from the kernel/common directory:

  check-susfs-pair.py --tree . --ksu drivers/kernelsu --susfs-patch <50_add.patch>

Exit code 0 = consistent, 1 = the pins drifted apart (prints every offender).
"""

import argparse
import pathlib
import re
import sys

KSU_SYM = re.compile(r'\bksu_[a-zA-Z0-9_]+')
SUSFS_CALL = re.compile(r'\b(susfs_[a-zA-Z0-9_]+)\s*\(')


def read_all(paths):
    out = []
    for p in paths:
        try:
            if p.is_file():
                out.append(p.read_text(errors='ignore'))
        except OSError:
            pass
    return '\n'.join(out)


def defines(text, sym):
    """Is `sym` defined (not just called) in this text?"""
    return re.search(r'\b' + re.escape(sym) + r'\s*\([^;{}]*\)\s*\n?\s*\{',
                     text) is not None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--tree', required=True,
                    help='kernel/common after the SUSFS copy + 50_ patch')
    ap.add_argument('--ksu', required=True,
                    help='KSU driver dir, e.g. drivers/kernelsu')
    ap.add_argument('--susfs-patch', required=True,
                    help='50_add_susfs_in_gki-android15-6.6.patch being applied')
    a = ap.parse_args()

    tree = pathlib.Path(a.tree)
    ksu_dir = pathlib.Path(a.ksu)
    ksu_txt = read_all(ksu_dir.rglob('*.c')) + read_all(ksu_dir.rglob('*.h'))

    patch_txt = pathlib.Path(a.susfs_patch).read_text(errors='ignore')
    added = '\n'.join(l[1:] for l in patch_txt.split('\n')
                      if l.startswith('+') and not l.startswith('+++'))

    # Kernel-side SUSFS as it exists in the tree right now.
    kernel_side = (
        read_all((tree / 'fs').glob('susfs*.c'))
        + read_all((tree / 'include/linux').glob('susfs*.h'))
        + read_all((tree / 'security/selinux').glob('*.c'))
    )

    bad = []

    # direction 1: SUSFS -> KSU
    for sym in sorted(set(KSU_SYM.findall(added))):
        if not re.search(r'\b' + re.escape(sym) + r'\b', ksu_txt):
            bad.append(f'{sym}(): added by the susfs kernel patch, missing from '
                       f'the pinned KSU tree')

    # direction 2: KSU -> kernel-side SUSFS
    called = set(SUSFS_CALL.findall(ksu_txt))
    for sym in sorted(called):
        if defines(kernel_side, sym) or defines(ksu_txt, sym):
            continue
        bad.append(f'{sym}(): called by the KSU tree, not provided by the pinned '
                   f'susfs4ksu kernel side nor defined in the KSU tree')

    if bad:
        print('::error::KSU/SUSFS pin mismatch - the two pins must move together:')
        for b in bad:
            print('::error::  - ' + b)
        return 1

    print(f'KSU/SUSFS pairing OK: {len(set(KSU_SYM.findall(added)))} ksu_*() refs '
          f'in the patch, {len(called)} susfs_*() calls in the KSU tree')
    return 0


if __name__ == '__main__':
    sys.exit(main())
