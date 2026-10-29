#!/usr/bin/env bash
# inject-os4-stubs.sh
#
# dash OS4 (HyperOS 4 / 6.6.118) 的厂商模块（node_cache / os_cpu_qi）注册在 13 个
# AOSP GKI 6.6 源里根本不存在的 MTK vendor-hook tracepoint 上，另有一个
# LZ4_compress_default 被 TRIM_UNUSED_KSYMS 裁掉了导出。
# 实测口径：638 个 .ko / 3652 个必需符号，droidspaces 自编内核缺 14，stock 缺 0
# （见 ~/下载/dash-os4/kernel-symbol-gap.md）。
#
# 本脚本做两件事：
#   1) 定义 + 导出这 13 个 tracepoint（+ LZ4 白名单），让模块能加载；
#   2) 在 AOSP 源里补回 MTK 的 call site，让探针真的会被调用（不是只加载不干活），
#      见 inject-os4-callsites.py：每个锚点都由 stock 内核反汇编逐点定位。
#
# 关键约束（KCFI）：模块探针在 -4(%func) 处带着类型哈希，内核 __traceiter_* 里也
# 带同一个常量（movk w17 两条），不一致会在 hook 触发时 brk。下面的 TP_PROTO 是
# 用 clang -fsanitize=kcfi 复算出与 stock 逐位相同的哈希后反推出来的，不能随意改：
#
#   hook                     kcfi hash    proto
#   remove_mapping           0xad16e271   (address_space*, folio*, bool)
#   remove_mapping_failed    0xad16e271   (address_space*, folio*, bool)
#   filemap_get_folio_end    0xaf94231e   (address_space*, folio*)
#   put_super                0xcf650130   (super_block*)
#   fuse_request_end_ext     0x6d1df6d6   (fuse_req*, task_struct*)
#   fuse_request_fetch       0x6d1df6d6   (fuse_req*, task_struct*)
#   mmap_lock_init/free      0xb294fbeb   (rw_semaphore*)
#   percpu_rwsem_init        0xdabec163   (percpu_rw_semaphore*)
#   rcu_boost_start/end      0x922a38d6   (rt_mutex*, task_struct*)
#   sync_rcu_wait_start/end  0x389e96a6   (task_struct*)
#
# 需要的环境：KDIR 指向 GKI 的 kernel/common 树根。
set -euo pipefail

: "${KDIR:?KDIR must point to the kernel/common tree root}"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

HOOK_HEADER="$KDIR/include/trace/hooks/dash_os4_stub.h"
VENDOR_HOOKS="$KDIR/drivers/android/vendor_hooks.c"
KMI_LIST="$KDIR/android/abi_gki_aarch64_mtk"

for f in "$VENDOR_HOOKS" "$KMI_LIST"; do
  [ -f "$f" ] || { echo "::error::missing $f"; exit 1; }
done

# ---------------------------------------------------------------- 1) 定义
{
  cat <<'EOF'
/* SPDX-License-Identifier: GPL-2.0 */
/* dash OS4 (HyperOS 4 / 6.6.118) MTK vendor hooks.
 *
 * These 13 android_vh_* tracepoints are imported by stock dash vendor modules
 * (node_cache.ko, os_cpu_qi.ko) but do not exist in AOSP GKI 6.6 source.
 * Prototypes are pinned by the KCFI type hashes embedded in the stock kernel's
 * __traceiter_* bodies and in the vendor modules' probes; the extern traceiter
 * declarations at the bottom are a compile-time guard on exactly those types
 * (a mismatch would otherwise be a #brk panic when the hook fires).
 */
#undef TRACE_SYSTEM
#define TRACE_SYSTEM dash_os4_stub
#undef TRACE_INCLUDE_PATH
#define TRACE_INCLUDE_PATH trace/hooks
#if !defined(_TRACE_HOOK_DASH_OS4_STUB_H) || defined(TRACE_HEADER_MULTI_READ)
#define _TRACE_HOOK_DASH_OS4_STUB_H
#include <trace/hooks/vendor_hooks.h>

struct address_space;
struct folio;
struct super_block;
struct fuse_req;
struct task_struct;
struct rw_semaphore;
struct percpu_rw_semaphore;
struct rt_mutex;

/* page-cache compression: node_cache.ko (FUSE / F2FS node cache) */
DECLARE_HOOK(android_vh_remove_mapping,
	TP_PROTO(struct address_space *mapping, struct folio *folio, bool reclaimed),
	TP_ARGS(mapping, folio, reclaimed));
DECLARE_HOOK(android_vh_remove_mapping_failed,
	TP_PROTO(struct address_space *mapping, struct folio *folio, bool reclaimed),
	TP_ARGS(mapping, folio, reclaimed));
DECLARE_HOOK(android_vh_filemap_get_folio_end,
	TP_PROTO(struct address_space *mapping, struct folio *folio),
	TP_ARGS(mapping, folio));
DECLARE_HOOK(android_vh_put_super,
	TP_PROTO(struct super_block *sb),
	TP_ARGS(sb));

/* QoS inheritance: os_cpu_qi.ko */
DECLARE_HOOK(android_vh_fuse_request_end_ext,
	TP_PROTO(struct fuse_req *req, struct task_struct *task),
	TP_ARGS(req, task));
DECLARE_HOOK(android_vh_fuse_request_fetch,
	TP_PROTO(struct fuse_req *req, struct task_struct *task),
	TP_ARGS(req, task));
DECLARE_HOOK(android_vh_mmap_lock_init,
	TP_PROTO(struct rw_semaphore *mmap_lock),
	TP_ARGS(mmap_lock));
DECLARE_HOOK(android_vh_mmap_lock_free,
	TP_PROTO(struct rw_semaphore *mmap_lock),
	TP_ARGS(mmap_lock));
DECLARE_HOOK(android_vh_percpu_rwsem_init,
	TP_PROTO(struct percpu_rw_semaphore *sem),
	TP_ARGS(sem));
DECLARE_HOOK(android_vh_rcu_boost_start,
	TP_PROTO(struct rt_mutex *mtx, struct task_struct *task),
	TP_ARGS(mtx, task));
DECLARE_HOOK(android_vh_rcu_boost_end,
	TP_PROTO(struct rt_mutex *mtx, struct task_struct *task),
	TP_ARGS(mtx, task));
DECLARE_HOOK(android_vh_sync_rcu_wait_start,
	TP_PROTO(struct task_struct *task),
	TP_ARGS(task));
DECLARE_HOOK(android_vh_sync_rcu_wait_end,
	TP_PROTO(struct task_struct *task),
	TP_ARGS(task));

/* Compile-time pin: these must stay byte-compatible with the declarations
 * above (and therefore with the KCFI hashes of the stock modules). */
extern int __traceiter_android_vh_remove_mapping(void *__data,
		struct address_space *mapping, struct folio *folio, bool reclaimed);
extern int __traceiter_android_vh_remove_mapping_failed(void *__data,
		struct address_space *mapping, struct folio *folio, bool reclaimed);
extern int __traceiter_android_vh_filemap_get_folio_end(void *__data,
		struct address_space *mapping, struct folio *folio);
extern int __traceiter_android_vh_put_super(void *__data,
		struct super_block *sb);
extern int __traceiter_android_vh_fuse_request_end_ext(void *__data,
		struct fuse_req *req, struct task_struct *task);
extern int __traceiter_android_vh_fuse_request_fetch(void *__data,
		struct fuse_req *req, struct task_struct *task);
extern int __traceiter_android_vh_mmap_lock_init(void *__data,
		struct rw_semaphore *mmap_lock);
extern int __traceiter_android_vh_mmap_lock_free(void *__data,
		struct rw_semaphore *mmap_lock);
extern int __traceiter_android_vh_percpu_rwsem_init(void *__data,
		struct percpu_rw_semaphore *sem);
extern int __traceiter_android_vh_rcu_boost_start(void *__data,
		struct rt_mutex *mtx, struct task_struct *task);
extern int __traceiter_android_vh_rcu_boost_end(void *__data,
		struct rt_mutex *mtx, struct task_struct *task);
extern int __traceiter_android_vh_sync_rcu_wait_start(void *__data,
		struct task_struct *task);
extern int __traceiter_android_vh_sync_rcu_wait_end(void *__data,
		struct task_struct *task);

#endif /* _TRACE_HOOK_DASH_OS4_STUB_H */
/* This part must be outside protection */
#include <trace/define_trace.h>
EOF
} > "$HOOK_HEADER"
echo "wrote $HOOK_HEADER"

HOOKS="android_vh_remove_mapping
android_vh_remove_mapping_failed
android_vh_filemap_get_folio_end
android_vh_put_super
android_vh_fuse_request_end_ext
android_vh_fuse_request_fetch
android_vh_mmap_lock_free
android_vh_mmap_lock_init
android_vh_percpu_rwsem_init
android_vh_rcu_boost_end
android_vh_rcu_boost_start
android_vh_sync_rcu_wait_end
android_vh_sync_rcu_wait_start"

# ------------------------------------------------- 2) 挂进 CREATE_TRACE_POINTS
if grep -q 'trace/hooks/dash_os4_stub.h' "$VENDOR_HOOKS"; then
  echo "vendor_hooks.c: include already present"
else
  # 插到最后一个 <trace/hooks/...> include 之后（不依赖具体文件名，AOSP 版本间会变）。
  python3 - "$VENDOR_HOOKS" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).read().splitlines()
idx = [i for i, l in enumerate(lines) if l.startswith('#include <trace/hooks/')]
if not idx:
    sys.exit("no <trace/hooks/...> include found")
lines.insert(idx[-1] + 1, '#include <trace/hooks/dash_os4_stub.h>')
with open(p, "w") as f:
    f.write("\n".join(lines) + "\n")
PY
  grep -q 'trace/hooks/dash_os4_stub.h' "$VENDOR_HOOKS" || { echo "::error::failed to add include"; exit 1; }
  echo "vendor_hooks.c: include added"
fi

# ------------------------------------------------------ 3) 导出 tracepoint
if grep -q 'EXPORT_TRACEPOINT_SYMBOL_GPL(android_vh_remove_mapping);' "$VENDOR_HOOKS"; then
  echo "vendor_hooks.c: exports already present"
else
  {
    echo ''
    echo '/* dash OS4 vendor hooks: exported so stock vendor modules can probe them */'
    for h in $HOOKS; do
      echo "EXPORT_TRACEPOINT_SYMBOL_GPL($h);"
    done
  } >> "$VENDOR_HOOKS"
  echo "vendor_hooks.c: $(echo "$HOOKS" | wc -l) exports appended"
fi

# --------------------------------- 4) KMI 白名单（否则 TRIM_UNUSED_KSYMS 裁掉导出）
# 追加到 android/abi_gki_aarch64_mtk 的 [abi_symbol_list] 段，保持排序/去重。
python3 - "$KMI_LIST" $HOOKS LZ4_compress_default <<'PY'
import sys

path = sys.argv[1]
hooks = sys.argv[2:-1]
extra = []
for h in hooks:
    # 与 AOSP/MTK KMI 列表的既有约定一致：每个 EXPORT_TRACEPOINT_SYMBOL_GPL 的 hook
    # 同时列 __tracepoint_ 与 __traceiter_（__SCK__ 静态调用符号不列，现有条目也没有）。
    extra += ["__tracepoint_" + h, "__traceiter_" + h]
extra.append(sys.argv[-1])

lines = open(path).read().splitlines()
header = "[abi_symbol_list]"
if lines and lines[0].strip() == header:
    body = lines[1:]
else:
    body = lines
    lines = [header]

existing = {l.strip() for l in body if l.strip()}
added = [s for s in extra if s not in existing]
all_syms = sorted(existing | set(extra))
with open(path, "w") as f:
    f.write(header + "\n")
    for s in all_syms:
        f.write("  " + s + "\n")
print("KMI list: added %d symbol(s), total %d" % (len(added), len(all_syms)))
PY

grep -q '__tracepoint_android_vh_remove_mapping' "$KMI_LIST" || { echo "::error::KMI whitelist patch failed"; exit 1; }
grep -q '^  LZ4_compress_default$' "$KMI_LIST" || { echo "::error::LZ4 whitelist patch failed"; exit 1; }

# ------------------------------------- 5) call sites（让探针真的会被调用）
python3 "$HERE/inject-os4-callsites.py" "$KDIR"

# ------------------------------------- 6) 自检：13 个 hook 的调用点必须都在源码里
for h in $HOOKS; do
  grep -qr "trace_${h}(" "$KDIR/mm" "$KDIR/fs" "$KDIR/kernel" \
    || { echo "::error::call site for ${h} missing after patch"; exit 1; }
done
echo "OS4 injection done: 13 tracehooks defined+exported, call sites patched, LZ4 whitelisted"