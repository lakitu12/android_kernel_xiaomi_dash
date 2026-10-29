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

# Single-variable on-device bisect switch (see patches/README.md):
#   HOOK_CALL_SITES=full                  (default) definitions+exports+all call sites
#   HOOK_CALL_SITES=none                  definitions+exports only
#   HOOK_CALL_SITES=0004,0005,...         only the listed call-site groups
# 2026-10-29: the full series bootlooped on device even though symbols and KCFI
# hashes were perfect, so the call sites must go in one group at a time.
#   group -> patch -> hooks
#   0004 mm/vmscan      remove_mapping, remove_mapping_failed
#   0005 mm/filemap     filemap_get_folio_end
#   0006 fs/super       put_super
#   0007 fs/fuse        fuse_request_end_ext, fuse_request_fetch
#   0008 kernel/fork    mmap_lock_init, mmap_lock_free
#   0009 percpu-rwsem   percpu_rwsem_init
#   0010 rcu            rcu_boost_start/end, sync_rcu_wait_start/end
ALL_SITES="0004 0005 0006 0007 0008 0009 0010"
# OS4_HOOKS=off drops the hook series entirely (0001-0003 included), i.e. a tree
# where node_cache.ko/os_cpu_qi.ko still fail to load exactly as on stock. That
# is the control that isolates "modules now load" from everything else:
# 2026-10-29 the definitions-only build (no call sites at all) still bootlooped,
# so the trigger is not our call sites.
OS4_HOOKS=${OS4_HOOKS:-on}
HOOK_CALL_SITES=${HOOK_CALL_SITES:-full}
case "$HOOK_CALL_SITES" in
  full) SITES=$ALL_SITES ;;
  none) SITES="" ;;
  *)    SITES=$(echo "$HOOK_CALL_SITES" | tr ',' ' ') ;;
esac
for g in $SITES; do
  case " $ALL_SITES " in
    *" $g "*) ;;
    *) echo "::error::unknown call-site group '$g' (known: $ALL_SITES)"; exit 1 ;;
  esac
done
SKIP_ARGS=()
for g in $ALL_SITES; do
  case " $SITES " in *" $g "*) ;; *) SKIP_ARGS+=(--skip "os4-vendor-hooks/$g") ;; esac
done
if [ "$OS4_HOOKS" = off ]; then
  SITES=""
  SKIP_ARGS+=(--skip 'os4-vendor-hooks/000[1-3]')
fi
# NO_LZ4_EXPORT=1 keeps all 13 hooks but drops the LZ4_compress_default line from
# the KMI whitelist. node_cache.ko needs 4 hooks AND LZ4 -> it stops loading;
# os_cpu_qi.ko needs only the 9 QoS hooks -> it keeps loading. That separates the
# two modules without another source patch.
NO_LZ4_EXPORT=${NO_LZ4_EXPORT:-0}
echo "OS4_HOOKS=$OS4_HOOKS HOOK_CALL_SITES=$HOOK_CALL_SITES (groups: ${SITES:-none})"
python3 "$HERE/apply-patches.py" --tree "$TREE" --patches "$ROOT/patches" "${SKIP_ARGS[@]+"${SKIP_ARGS[@]}"}"

if [ "$NO_LZ4_EXPORT" = 1 ]; then
  ABI="$TREE/android/abi_gki_aarch64_dash_os4"
  [ -f "$ABI" ] || { echo "::error::NO_LZ4_EXPORT=1 but $ABI is missing"; exit 1; }
  sed -i '/^[[:space:]]*LZ4_compress_default$/d' "$ABI"
  grep -q 'LZ4_compress_default' "$ABI" && { echo "::error::failed to drop LZ4 from the KMI list"; exit 1; }
  echo "NO_LZ4_EXPORT=1: dropped LZ4_compress_default -> node_cache will fail to load"
fi

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
if [ "$OS4_HOOKS" = off ]; then
  # control build: the hook series must be entirely absent, exactly like stock
  [ -f "$H" ] && fail "OS4_HOOKS=off but the hook header is present"
  grep -q 'dash_os4_stub' "$TREE/drivers/android/vendor_hooks.c" && fail "OS4_HOOKS=off but vendor_hooks.c still includes the stub header"
  [ -f "$TREE/android/abi_gki_aarch64_dash_os4" ] && fail "OS4_HOOKS=off but the KMI list is present"
  echo "patches applied + verified (OS4 hooks disabled on purpose):"
  echo "  trusty-rescue      driver, Kconfig/Makefile hook, nvhe cmdline, CONFIG_TRUSTY_RESCUE=y"
  echo "  pid-max-clamp      pid space clamped to 32768"
  echo "  os4-vendor-hooks   OFF - node_cache/os_cpu_qi will fail to load as on stock"
  exit 0
fi
[ -f "$H" ] || fail "hook header missing"
grep -q "TRACE_SYSTEM dash_os4_stub" "$H" || fail "hook header TRACE_SYSTEM wrong"
grep -q 'include <trace/hooks/dash_os4_stub.h>' "$TREE/drivers/android/vendor_hooks.c" \
  || fail "vendor_hooks.c does not include the stub header"
# hook -> call-site group (must match the patch groups above)
hook_group() {
  case "$1" in
    android_vh_remove_mapping|android_vh_remove_mapping_failed) echo 0004 ;;
    android_vh_filemap_get_folio_end)                          echo 0005 ;;
    android_vh_put_super)                                      echo 0006 ;;
    android_vh_fuse_request_end_ext|android_vh_fuse_request_fetch) echo 0007 ;;
    android_vh_mmap_lock_init|android_vh_mmap_lock_free)       echo 0008 ;;
    android_vh_percpu_rwsem_init)                              echo 0009 ;;
    android_vh_rcu_boost_start|android_vh_rcu_boost_end|android_vh_sync_rcu_wait_start|android_vh_sync_rcu_wait_end) echo 0010 ;;
  esac
}

for h in $HOOKS; do
  grep -q "DECLARE_HOOK($h," "$H" || fail "DECLARE_HOOK($h) missing"
  grep -q "EXPORT_TRACEPOINT_SYMBOL_GPL($h);" "$TREE/drivers/android/vendor_hooks.c" \
    || fail "export of $h missing"
  g=$(hook_group "$h")
  case " $SITES " in
    *" $g "*)
      grep -qr "trace_${h}(" "$TREE/mm" "$TREE/fs" "$TREE/kernel" \
        || fail "call site for $h missing (group $g selected)" ;;
    *)
      if grep -qr "trace_${h}(" "$TREE/mm" "$TREE/fs" "$TREE/kernel"; then
        fail "call site for $h present although group $g is not selected"
      fi ;;
  esac
done
[ -f "$TREE/android/abi_gki_aarch64_dash_os4" ] || fail "KMI symbol list missing"
grep -q 'abi_gki_aarch64_dash_os4' "$TREE/BUILD.bazel" || fail "KMI list not wired into BUILD.bazel"
if [ "$NO_LZ4_EXPORT" = 1 ]; then
  grep -q 'LZ4_compress_default' "$TREE/android/abi_gki_aarch64_dash_os4" \
    && fail "NO_LZ4_EXPORT=1 but LZ4 is still whitelisted"
else
  grep -q '^  LZ4_compress_default$' "$TREE/android/abi_gki_aarch64_dash_os4" || fail "LZ4 not whitelisted"
fi

echo "patches applied + verified:"
echo "  trusty-rescue      driver, Kconfig/Makefile hook, nvhe cmdline, CONFIG_TRUSTY_RESCUE=y"
echo "  os4-vendor-hooks   13 tracehooks defined/exported/whitelisted, call sites: $HOOK_CALL_SITES"
echo "  (build-time gate: verify-os4-kcfi.py compares each __traceiter_* hash with stock)"