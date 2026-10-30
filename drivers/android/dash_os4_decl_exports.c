// SPDX-License-Identifier: GPL-2.0-only
/*
 * dash OS4 QoS tracehooks: export-only translation unit.
 *
 * The stock OS4 kernel exported android_vh_mmap_lock_init/_free from a unit that
 * only *declared* the tracepoints (no CREATE_TRACE_POINTS). genksyms derives a
 * tracepoint symbol's modversions CRC from the declaration text visible at the
 * EXPORT site: the DEFINE_TRACE_FN definition carries
 *
 *     struct tracepoint __tracepoint_X __used __section("__tracepoints") = {...}
 *
 * and those attribute tokens change the CRC, while the bare
 *
 *     extern struct tracepoint __tracepoint_X;
 *
 * does not. os_cpu_qi.ko verifies the CRC at load time and rejects a mismatch
 * ("disagrees about version of symbol ..." / -EINVAL), so these two exports
 * must stay in a declaration-only unit to reproduce the stock CRCs:
 *
 *     __tracepoint_android_vh_mmap_lock_init  0x615d194b
 *     __tracepoint_android_vh_mmap_lock_free  0xa301bcc9
 *
 * The tracepoint objects themselves are still defined in vendor_hooks.c via the
 * CREATE_TRACE_POINTS pass; this unit only carries the EXPORT statements.
 *
 * Verified on-device 2026-10-29: with this layout os_cpu_qi.ko loads with no
 * kcrctab post-processing (556 -> 584 modules, QoS chain comes up).
 */
#include <linux/tracepoint.h>
#include <trace/hooks/dash_os4_stub.h>

EXPORT_TRACEPOINT_SYMBOL_GPL(android_vh_mmap_lock_init);
EXPORT_TRACEPOINT_SYMBOL_GPL(android_vh_mmap_lock_free);
