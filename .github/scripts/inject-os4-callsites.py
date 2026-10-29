#!/usr/bin/env python3
"""Patch AOSP GKI 6.6.118 call sites for the 13 dash-OS4 (MTK) vendor hooks.

Why this exists
---------------
dash OS4 (HyperOS 4 / 6.6.118) ships vendor modules (node_cache, os_cpu_qi) that
register probes on 13 `android_vh_*` tracepoints which do NOT exist in AOSP GKI
6.6 source. Defining + exporting the tracepoints lets the modules load, but with
no call site the probes never run and the features (FUSE/F2FS page-cache
compression, QoS inheritance) stay silently dead.

This patch adds the call sites MTK added, on top of the AOSP 6.6.118 tree.

Prototype provenance (objective, not guessed)
---------------------------------------------
Every one of the 13 hooks was PINNED by KCFI type hashes: the stock dash kernel's
`__traceiter_android_vh_*` embeds the expected probe type hash as an immediate
(movk w17 pair) before `blr`, and the vendor .ko probes embed the same value at
-4(%func). Re-declaring a candidate TP_PROTO and compiling with
`clang -fsanitize=kcfi` reproduces those hashes bit-exactly, so the prototypes in
inject-os4-stubs.sh are provably identical to MTK's declarations:

  hook                        kcfi hash    proto
  remove_mapping              0xad16e271   (address_space*, folio*, bool)
  remove_mapping_failed       0xad16e271   (address_space*, folio*, bool)
  filemap_get_folio_end       0xaf94231e   (address_space*, folio*)
  put_super                   0xcf650130   (super_block*)
  fuse_request_end_ext        0x6d1df6d6   (fuse_req*, task_struct*)
  fuse_request_fetch          0x6d1df6d6   (fuse_req*, task_struct*)
  mmap_lock_init/free         0xb294fbeb   (rw_semaphore*)
  percpu_rwsem_init           0xdabec163   (percpu_rw_semaphore*)
  rcu_boost_start/end         0x922a38d6   (rt_mutex*, task_struct*)
  sync_rcu_wait_start/end     0x389e96a6   (task_struct*)

Call-site placement was recovered from the stock kernel by disassembling every
`bl __traceiter_android_vh_*` in stock_Image and matching the surrounding code to
the AOSP source (same 6.6.118 base). Every anchor below must match exactly once;
a miss aborts the build instead of silently shipping a kernel whose hooks never
fire.
"""

import os
import sys

INCLUDE_LINE = "#include <trace/hooks/dash_os4_stub.h>\n"


class PatchError(Exception):
    pass


class Tree:
    def __init__(self, root):
        self.root = root
        self.changed = []

    def path(self, rel):
        return os.path.join(self.root, rel)

    def read(self, rel):
        with open(self.path(rel)) as f:
            return f.read()

    def write(self, rel, text):
        with open(self.path(rel), "w") as f:
            f.write(text)

    def add_include(self, rel, after=None):
        text = self.read(rel)
        if INCLUDE_LINE in text:
            return
        lines = text.splitlines(keepends=True)
        if after is None:
            # End of the FIRST include block. (Files like kernel/fork.c have
            # legitimate late #includes such as <linux/init_task.h>; inserting
            # after those would leave earlier uses undeclared.)
            idx = next(i for i, l in enumerate(lines) if l.startswith("#include"))
            i = idx + 1
            while i < len(lines):
                l = lines[i]
                if l.startswith("#include"):
                    idx = i
                elif l.strip() and not l.startswith(("/*", " *", "//")):
                    break
                i += 1
        else:
            hits = [i for i, l in enumerate(lines) if l.rstrip("\n") == after]
            if len(hits) != 1:
                raise PatchError("%s: include anchor %r found %d times"
                                 % (rel, after, len(hits)))
            idx = hits[0]
        lines.insert(idx + 1, INCLUDE_LINE)
        self.write(rel, "".join(lines))
        self.changed.append("%s (include)" % rel)

    def sub(self, rel, old, new, label, marker=None):
        text = self.read(rel)
        if marker and marker in text:
            return  # already patched
        n = text.count(old)
        if n != 1:
            raise PatchError("%s: %s anchor occurs %d time(s), expected 1:\n---\n%s\n---"
                             % (rel, label, n, old))
        self.write(rel, text.replace(old, new, 1))
        self.changed.append("%s: %s" % (rel, label))


# kernel/rcu: both hook sites live in .h files textually included by tree.c long
# after its include block, so a single include in tree.c covers them (and avoids
# redefining TRACE_SYSTEM in the middle of a translation unit).
RCU_INCLUDE_IN = ("kernel/rcu/tree.c", '#include "rcu.h"')

INCLUDE_TARGETS = [
    "mm/vmscan.c",
    "mm/filemap.c",
    "fs/super.c",
    "fs/fuse/dev.c",
    "kernel/fork.c",
    "kernel/locking/percpu-rwsem.c",
]


def patch_all(root):
    t = Tree(root)

    for rel in INCLUDE_TARGETS:
        t.add_include(rel)
    t.add_include(*RCU_INCLUDE_IN)

    # ---------------------------------------------- mm/vmscan.c: __remove_mapping
    # success path: hook right after the BUG_ON()s, i.e. before the
    # folio_test_swapcache() branch (stock: bl at +0x2bc, back-edge to +0x58).
    t.sub("mm/vmscan.c",
          "\tBUG_ON(mapping != folio_mapping(folio));\n"
          "\n"
          "\tif (!folio_test_swapcache(folio))\n",
          "\tBUG_ON(mapping != folio_mapping(folio));\n\n"
          "\ttrace_android_vh_remove_mapping(mapping, folio, reclaimed);\n\n"
          "\tif (!folio_test_swapcache(folio))\n",
          "remove_mapping",
          marker="trace_android_vh_remove_mapping(")

    # cannot_free path: hook right before `return 0;` (stock: bl at +0x35c,
    # back-edge to the `mov w0, wzr` of the return).
    t.sub("mm/vmscan.c",
          "\txa_unlock_irq(&mapping->i_pages);\n"
          "\tif (!folio_test_swapcache(folio))\n"
          "\t\tspin_unlock(&mapping->host->i_lock);\n"
          "\treturn 0;\n",
          "\txa_unlock_irq(&mapping->i_pages);\n"
          "\tif (!folio_test_swapcache(folio))\n"
          "\t\tspin_unlock(&mapping->host->i_lock);\n"
          "\n\ttrace_android_vh_remove_mapping_failed(mapping, folio, reclaimed);\n\n"
          "\treturn 0;\n",
          "remove_mapping_failed",
          marker="trace_android_vh_remove_mapping_failed(")

    # ------------------------------------------- mm/filemap.c: __filemap_get_folio
    # right before `return folio;` (stock: bl at +0x414, jump into the epilogue).
    t.sub("mm/filemap.c",
          "\tif (!folio)\n"
          "\t\treturn ERR_PTR(-ENOENT);\n"
          "\treturn folio;\n",
          "\tif (!folio)\n"
          "\t\treturn ERR_PTR(-ENOENT);\n"
          "\n\ttrace_android_vh_filemap_get_folio_end(mapping, folio);\n\n"
          "\treturn folio;\n",
          "filemap_get_folio_end",
          marker="trace_android_vh_filemap_get_folio_end(")

    # ---------------------------------------------- fs/super.c: generic_shutdown_super
    # after the ->s_dio_done_wq teardown, before the fs' ->put_super().
    t.sub("fs/super.c",
          "\t\tif (sop->put_super)\n\t\t\tsop->put_super(sb);\n",
          "\t\ttrace_android_vh_put_super(sb);\n\n"
          "\t\tif (sop->put_super)\n\t\t\tsop->put_super(sb);\n",
          "put_super",
          marker="trace_android_vh_put_super(")

    # --------------------------------------------------------- fs/fuse/dev.c hooks
    # fuse_request_end(): MTK calls _ext right after upstream's
    # trace_android_vh_fuse_request_end(current) in the !FR_BACKGROUND branch.
    t.sub("fs/fuse/dev.c",
          "\t\ttrace_android_vh_fuse_request_end(current);\n",
          "\t\ttrace_android_vh_fuse_request_end(current);\n"
          "\t\ttrace_android_vh_fuse_request_end_ext(req, current);\n",
          "fuse_request_end_ext",
          marker="trace_android_vh_fuse_request_end_ext(")

    # fuse_dev_do_read(): right after the request leaves fiq->pending, before
    # `args = req->args;` (stock: bl at +0x27c, x1=req, x2=current).
    t.sub("fs/fuse/dev.c",
          "\tclear_bit(FR_PENDING, &req->flags);\n"
          "\tlist_del_init(&req->list);\n"
          "\tspin_unlock(&fiq->lock);\n",
          "\tclear_bit(FR_PENDING, &req->flags);\n"
          "\tlist_del_init(&req->list);\n"
          "\tspin_unlock(&fiq->lock);\n"
          "\n\ttrace_android_vh_fuse_request_fetch(req, current);\n",
          "fuse_request_fetch",
          marker="trace_android_vh_fuse_request_fetch(")

    # ------------------------------------------------ kernel/fork.c: per-mm mmap_lock
    # mm_init(): right after mmap_init_lock(mm); MTK hands over &mm->mmap_lock.
    t.sub("kernel/fork.c",
          "\tmmap_init_lock(mm);\n",
          "\tmmap_init_lock(mm);\n\ttrace_android_vh_mmap_lock_init(&mm->mmap_lock);\n",
          "mmap_lock_init",
          marker="trace_android_vh_mmap_lock_init(")

    # __mmdrop(): before free_mm(mm) (stock: bl at +0x1bc, then kmem_cache_free).
    t.sub("kernel/fork.c",
          "\tpercpu_counter_destroy_many(mm->rss_stat, NR_MM_COUNTERS);\n"
          "\n"
          "\tfree_mm(mm);\n",
          "\tpercpu_counter_destroy_many(mm->rss_stat, NR_MM_COUNTERS);\n"
          "\n\ttrace_android_vh_mmap_lock_free(&mm->mmap_lock);\n"
          "\tfree_mm(mm);\n",
          "mmap_lock_free",
          marker="trace_android_vh_mmap_lock_free(")

    # ------------------------------------- kernel/locking/percpu-rwsem.c: init hook
    # right after atomic_set(&sem->block, 0) (stock: bl at +0xb4, w0 = 0 return).
    t.sub("kernel/locking/percpu-rwsem.c",
          "\tatomic_set(&sem->block, 0);\n",
          "\tatomic_set(&sem->block, 0);\n\ttrace_android_vh_percpu_rwsem_init(sem);\n",
          "percpu_rwsem_init",
          marker="trace_android_vh_percpu_rwsem_init(")

    # ------------------------------- kernel/rcu/tree_exp.h: synchronize_rcu_expedited
    # wrap the wait_event() that blocks waiting for the expedited GP.
    t.sub("kernel/rcu/tree_exp.h",
          "\twait_event(rnp->exp_wq[rcu_seq_ctr(s) & 0x3],\n"
          "\t\t   sync_exp_work_done(s));\n",
          "\ttrace_android_vh_sync_rcu_wait_start(current);\n"
          "\twait_event(rnp->exp_wq[rcu_seq_ctr(s) & 0x3],\n"
          "\t\t   sync_exp_work_done(s));\n"
          "\ttrace_android_vh_sync_rcu_wait_end(current);\n",
          "sync_rcu_wait_start/end",
          marker="trace_android_vh_sync_rcu_wait_start(")

    # ----------------------------- kernel/rcu/tree_plugin.h: rcu_boost_kthread
    # around the artificial rt_mutex boost (stock: bl at +0x2d4 / +0x33c,
    # x1 = &rnp->boost_mtx, x2 = task being boosted).
    t.sub("kernel/rcu/tree_plugin.h",
          "\t/* Lock only for side effect: boosts task t's priority. */\n"
          "\trt_mutex_lock(&rnp->boost_mtx);\n"
          "\trt_mutex_unlock(&rnp->boost_mtx);  /* Then keep lockdep happy. */\n",
          "\ttrace_android_vh_rcu_boost_start(&rnp->boost_mtx, t);\n"
          "\t/* Lock only for side effect: boosts task t's priority. */\n"
          "\trt_mutex_lock(&rnp->boost_mtx);\n"
          "\trt_mutex_unlock(&rnp->boost_mtx);  /* Then keep lockdep happy. */\n"
          "\ttrace_android_vh_rcu_boost_end(&rnp->boost_mtx, t);\n",
          "rcu_boost_start/end",
          marker="trace_android_vh_rcu_boost_start(")

    return t.changed


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("KDIR", "")
    if not root or not os.path.isdir(root):
        sys.exit("usage: %s <kernel/common tree>  (or set KDIR)" % sys.argv[0])
    try:
        changed = patch_all(root)
    except PatchError as e:
        sys.exit("::error::OS4 call-site patch failed: %s" % e)
    for c in changed:
        print("  + %s" % c)
    print("OS4 call sites: %d change(s)" % len(changed))


if __name__ == "__main__":
    main()