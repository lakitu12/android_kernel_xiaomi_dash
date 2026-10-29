#!/usr/bin/env bash
# inject-os4-stubs.sh
#
# dash OS4 (HyperOS 4 / 6.6.118) 的厂商模块（node_cache / os_cpu_qi）注册在 13 个
# AOSP GKI 6.6 源里根本不存在的 MTK vendor-hook tracepoint 上，另有一个
# LZ4_compress_default 被 TRIM_UNUSED_KSYMS 裁掉了导出。
# 实测口径：638 个 .ko / 3652 个必需符号，droidspaces 自编内核缺 14，stock 缺 0
# （见 ~/下载/dash-os4/kernel-symbol-gap.md）。
#
# 这部分改动统一以「标准补丁」形式维护在 .github/patches/os4-vendor-hooks/：
#   0001  include/trace/hooks/dash_os4_stub.h      13 个 hook 的 DECLARE_HOOK 定义
#   0002  drivers/android/vendor_hooks.c           挂进 CREATE_TRACE_POINTS + 导出
#   0003  BUILD.bazel + android/abi_gki_aarch64_dash_os4   KMI 白名单（含 LZ4）
#   0004~ 各调用点（vmscan / filemap / super / fuse / fork / percpu-rwsem / rcu）
#
# 原型不是猜的：TP_PROTO 由 stock 内核 __traceiter_* 里的 KCFI 类型哈希立即数
# 与模块探针 -4(%func) 的哈希逐位反推（用 clang -fsanitize=kcfi 复算对齐），
# 调用点由 stock Image 反汇编里每一条 bl __traceiter_* 定位。详见
# ~/下载/dash-os4/os4-hooks-callsite-map.md。
#
# 需要的环境：KDIR 指向 GKI 的 kernel/common 树根。
set -euo pipefail

: "${KDIR:?KDIR must point to the kernel/common tree root}"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PATCHES="$HERE/../patches/os4-vendor-hooks"

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

for f in "$KDIR/drivers/android/vendor_hooks.c" "$KDIR/BUILD.bazel"; do
  [ -f "$f" ] || { echo "::error::missing $f"; exit 1; }
done

# ------------------------------------------------ 1) 打补丁（统一入口）
python3 "$HERE/apply-patches.py" --tree "$KDIR" --patches "$PATCHES"

# ------------------------------------------------ 2) 自检（补丁真的生效了）
fail() { echo "::error::OS4 patch self-check failed: $*"; exit 1; }

H="$KDIR/include/trace/hooks/dash_os4_stub.h"
[ -f "$H" ] || fail "hook header missing"
grep -q "TRACE_SYSTEM dash_os4_stub" "$H" || fail "hook header TRACE_SYSTEM wrong"
for h in $HOOKS; do
  grep -q "DECLARE_HOOK($h," "$H" || fail "DECLARE_HOOK($h) missing"
  grep -q "EXPORT_TRACEPOINT_SYMBOL_GPL($h);" "$KDIR/drivers/android/vendor_hooks.c" \
    || fail "export of $h missing"
  grep -qr "trace_${h}(" "$KDIR/mm" "$KDIR/fs" "$KDIR/kernel" \
    || fail "call site for $h missing"
done
grep -q 'include <trace/hooks/dash_os4_stub.h>' "$KDIR/drivers/android/vendor_hooks.c" \
  || fail "vendor_hooks.c does not include the stub header"

[ -f "$KDIR/android/abi_gki_aarch64_dash_os4" ] || fail "KMI symbol list missing"
grep -q 'abi_gki_aarch64_dash_os4' "$KDIR/BUILD.bazel" || fail "KMI list not wired into BUILD.bazel"
grep -q '^  LZ4_compress_default$' "$KDIR/android/abi_gki_aarch64_dash_os4" || fail "LZ4 not whitelisted"
grep -q '^  __tracepoint_android_vh_remove_mapping$' "$KDIR/android/abi_gki_aarch64_dash_os4" \
  || fail "tracepoint symbols not whitelisted"

echo "OS4 patches applied: 13 tracehooks defined+exported+whitelisted, call sites in place"
echo "  (build-time gate: verify-os4-kcfi.py compares each __traceiter_* hash with stock)"