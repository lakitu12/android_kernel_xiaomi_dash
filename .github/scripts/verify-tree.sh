#!/usr/bin/env bash
# verify-tree.sh <kernel tree>
#
# 我方的内核 delta（13 个 OS4 vendor hook + trusty-rescue + pid 钳制）现在**烘在树里**
# 而不是构建时打补丁（2026-10-30 起，见 `git log 537ebbfb..`）。所以这一步不做任何
# 修改，只做源码级门禁：任何一条改动丢了（错误合并、误 revert、上游 tag 误覆盖）
# 立刻失败，而不是 20 分钟后编出一个静默功能不全的内核。
#
# 二进制层的门禁在 workflow 的 version gate：CONFIG_TRUSTY_RESCUE / nvhe cmdline /
# 13 个 __ksymtab_* 导出 / verify-os4-kcfi.py 的 KCFI 哈希逐位比对。
set -euo pipefail

TREE=${1:?usage: $0 <kernel tree>}
fail() { echo "::error::in-tree dash delta broken: $*"; exit 1; }

[ -d "$TREE" ] || fail "no such tree: $TREE"

# ------------------------------------------------ trusty-rescue
[ -f "$TREE/drivers/trusty_rescue/trusty_rescue.c" ] || fail "drivers/trusty_rescue/trusty_rescue.c missing"
grep -q 'trusty_rescue/Kconfig' "$TREE/drivers/Kconfig" || fail "drivers/Kconfig not hooked"
grep -q 'trusty_rescue/' "$TREE/drivers/Makefile" || fail "drivers/Makefile not hooked"
# 我们的配置全在单独的 fragment 里（gki_defconfig 必须保持上游原样）
DEF="$TREE/arch/arm64/configs/gki_defconfig"
FRAG="$TREE/arch/arm64/configs/dash_gki.fragment"
[ -f "$FRAG" ] || fail "arch/arm64/configs/dash_gki.fragment missing"
grep -q 'dash_gki.fragment' "$TREE/BUILD.bazel" \
  || fail "defconfig_fragments does not wire dash_gki.fragment into BUILD.bazel"
grep -q 'CONFIG_TRUSTY_RESCUE=y' "$FRAG" || fail "CONFIG_TRUSTY_RESCUE=y missing from dash_gki.fragment"
grep -q 'kvm-arm.mode=nvhe' "$FRAG" || fail "fragment cmdline is not kvm-arm.mode=nvhe"
grep -q 'kvm-arm.mode=protected' "$FRAG" && fail "fragment cmdline flipped back to kvm-arm.mode=protected"
grep -qE '^CONFIG_(SYSVIPC|TRUSTY_RESCUE)=y|^# CONFIG_MODULE_SIG_PROTECT' "$DEF" \
  && fail "our config leaked back into gki_defconfig (keep it pristine, use the fragment)"

# ------------------------------------------------ OS4 vendor hooks (13)
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

H="$TREE/include/trace/hooks/dash_os4_stub.h"
[ -f "$H" ] || fail "include/trace/hooks/dash_os4_stub.h missing"
grep -q "TRACE_SYSTEM dash_os4_stub" "$H" || fail "hook header TRACE_SYSTEM wrong"
grep -q 'include <trace/hooks/dash_os4_stub.h>' "$TREE/drivers/android/vendor_hooks.c" \
  || fail "vendor_hooks.c does not include the stub header"
[ -f "$TREE/drivers/android/dash_os4_decl_exports.c" ] \
  || fail "drivers/android/dash_os4_decl_exports.c (declaration-only CRC TU) missing"
grep -q 'dash_os4_decl_exports.o' "$TREE/drivers/android/Makefile" \
  || fail "declaration-only CRC TU not wired into drivers/android/Makefile"

for h in $HOOKS; do
  grep -q "DECLARE_HOOK($h," "$H" || fail "DECLARE_HOOK($h) missing"
  # 13 个 export：11 个在 vendor_hooks.c，mmap_lock_init/_free 在只声明的 TU 里
  #（genksyms 只在“没见过 DEFINE_TRACE_FN 定义”时才算出 stock 的 CRC）
  grep -q "EXPORT_TRACEPOINT_SYMBOL_GPL($h);" \
      "$TREE/drivers/android/vendor_hooks.c" \
      "$TREE/drivers/android/dash_os4_decl_exports.c" 2>/dev/null \
    || fail "export of $h missing"
  grep -qr "trace_${h}(" "$TREE/mm" "$TREE/fs" "$TREE/kernel" \
    || fail "call site of $h missing (hook would never fire)"
done

[ -f "$TREE/android/abi_gki_aarch64_dash_os4" ] || fail "android/abi_gki_aarch64_dash_os4 (KMI whitelist) missing"
grep -q 'abi_gki_aarch64_dash_os4' "$TREE/BUILD.bazel" || fail "KMI whitelist not wired into BUILD.bazel"
grep -q '^  LZ4_compress_default$' "$TREE/android/abi_gki_aarch64_dash_os4" || fail "LZ4_compress_default not whitelisted"

# ------------------------------------------------ DroidSpaces: kABI padding + configs
# SYSVIPC 会改 task_struct 布局，所以字段挪进了 ANDROID_KABI_RESERVE(6..8)，
# 让 stock（无 SYSVIPC）与我们的布局逐字节一致。
grep -q 'ANDROID_KABI_USE(6, struct sysv_sem sysvsem)' "$TREE/include/linux/sched.h" \
  || fail "DroidSpaces SYSVIPC kABI padding missing from include/linux/sched.h"
for sym in SYSVIPC POSIX_MQUEUE IPC_NS PID_NS DEVTMPFS USER_NS \
           TMPFS_XATTR TMPFS_POSIX_ACL NETFILTER_XT_MATCH_ADDRTYPE IP_SET \
           NETFILTER_XT_SET KPROBES KALLSYMS KALLSYMS_ALL; do
  grep -q "^CONFIG_${sym}=y$" "$FRAG" || fail "dash_gki.fragment lost CONFIG_${sym}=y"
done
grep -q '^# CONFIG_MODULE_SIG_PROTECT is not set$' "$FRAG" \
  || fail "MODULE_SIG_PROTECT must stay off (system_dlkm protected-symbol refusal)"
# ------------------------------------------------ pid clamp
grep -qE '^#define PID_MAX_LIMIT[[:space:]]+PID_MAX_DEFAULT' "$TREE/include/linux/threads.h" \
  || fail "PID_MAX_LIMIT is not clamped to PID_MAX_DEFAULT in include/linux/threads.h"
grep -q 'pid_max_max = PID_MAX_DEFAULT' "$TREE/kernel/pid.c" \
  || fail "pid_max_max hard clamp missing from kernel/pid.c"

echo "in-tree dash delta verified:"
echo "  trusty-rescue      driver + Kconfig/Makefile hook + nvhe cmdline + CONFIG_TRUSTY_RESCUE=y"
echo "  DroidSpaces        SYSVIPC kABI padding in sched.h + dash_gki.fragment (SYSVIPC/IPC_NS/PID_NS/DEVTMPFS/..., MODULE_SIG_PROTECT off), gki_defconfig untouched"
echo "  os4-vendor-hooks   13 tracehooks declared/exported/called, KMI list wired (13 + LZ4)"
echo "  pid-max-clamp      pid space clamped to 32768"
echo "  (binary gates still to run after the build: CONFIG checks, __ksymtab_*, KCFI hashes)"
