#!/usr/bin/env bash
# apply-tree-patches.sh <kernel/common 树>
#
# dash 自编内核对 GKI 源树的**全部**改动都放在仓库根的 patches/ 下，以标准
# unified diff 维护，由 .github/scripts/apply-patches.py 统一应用：
#
#   patches/trusty-rescue/     gz 被抹除（nvhe/pKVM）启动时的相机链自救驱动
#   patches/os4-vendor-hooks/  dash OS4 厂商模块需要的 13 个 MTK vendor hook
#
# 应用器只做 git apply / patch，失败即中止构建（不会「悄悄插错位置」）。
# 打完后这里再做一次自检，确保每一条改动真的落地了。
set -euo pipefail

TREE=${1:?usage: $0 <kernel/common tree>}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)

[ -d "$TREE" ] || { echo "::error::no such tree: $TREE"; exit 1; }
[ -d "$ROOT/patches" ] || { echo "::error::patches/ missing"; exit 1; }

fail() { echo "::error::patch self-check failed: $*"; exit 1; }

python3 "$HERE/apply-patches.py" --tree "$TREE" --patches "$ROOT/patches"

# ------------------------------------------------ trusty-rescue 自检
[ -f "$TREE/drivers/trusty_rescue/trusty_rescue.c" ] || fail "trusty_rescue.c missing"
grep -q 'trusty_rescue/Kconfig' "$TREE/drivers/Kconfig" || fail "drivers/Kconfig not hooked"
grep -q 'trusty_rescue/' "$TREE/drivers/Makefile" || fail "drivers/Makefile not hooked"
DEF="$TREE/arch/arm64/configs/gki_defconfig"
grep -q 'CONFIG_TRUSTY_RESCUE=y' "$DEF" || fail "TRUSTY_RESCUE not enabled"
grep -q 'kvm-arm.mode=nvhe' "$DEF" || fail "cmdline not flipped to nvhe"
grep -q 'kvm-arm.mode=protected' "$DEF" && fail "protected cmdline still present"

# ------------------------------------------------ OS4 vendor hooks 自检
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
[ -f "$H" ] || fail "hook header missing"
grep -q "TRACE_SYSTEM dash_os4_stub" "$H" || fail "hook header TRACE_SYSTEM wrong"
grep -q 'include <trace/hooks/dash_os4_stub.h>' "$TREE/drivers/android/vendor_hooks.c" \
  || fail "vendor_hooks.c does not include the stub header"
for h in $HOOKS; do
  grep -q "DECLARE_HOOK($h," "$H" || fail "DECLARE_HOOK($h) missing"
  grep -q "EXPORT_TRACEPOINT_SYMBOL_GPL($h);" "$TREE/drivers/android/vendor_hooks.c" \
    || fail "export of $h missing"
  grep -qr "trace_${h}(" "$TREE/mm" "$TREE/fs" "$TREE/kernel" || fail "call site for $h missing"
done
[ -f "$TREE/android/abi_gki_aarch64_dash_os4" ] || fail "KMI symbol list missing"
grep -q 'abi_gki_aarch64_dash_os4' "$TREE/BUILD.bazel" || fail "KMI list not wired into BUILD.bazel"
grep -q '^  LZ4_compress_default$' "$TREE/android/abi_gki_aarch64_dash_os4" || fail "LZ4 not whitelisted"

echo "patches applied + verified:"
echo "  trusty-rescue      driver, Kconfig/Makefile hook, nvhe cmdline, CONFIG_TRUSTY_RESCUE=y"
echo "  os4-vendor-hooks   13 tracehooks defined/exported/whitelisted, call sites in place"
echo "  (build-time gate: verify-os4-kcfi.py compares each __traceiter_* hash with stock)"