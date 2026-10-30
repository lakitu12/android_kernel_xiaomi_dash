/* SPDX-License-Identifier: GPL-2.0 */
/* dash OS4 (HyperOS 4 / 6.6.118) MTK vendor hooks.
 *
 * These 13 android_vh_* tracepoints are imported by stock dash vendor modules
 * (node_cache.ko, os_cpu_qi.ko) but do not exist in AOSP GKI 6.6 source.
 *
 * Prototypes are pinned by the KCFI type hashes embedded in the stock kernel's
 * __traceiter_* bodies and in the vendor modules' probes (see the extern
 * declarations at the bottom, which turn a future mismatch into a compile
 * error instead of a #brk panic when the hook fires):
 *
 *   remove_mapping / _failed          0xad16e271
 *   filemap_get_folio_end             0xaf94231e
 *   put_super                         0xcf650130
 *   fuse_request_end_ext / _fetch     0x6d1df6d6
 *   mmap_lock_init / _free            0xb294fbeb
 *   percpu_rwsem_init                 0xdabec163
 *   rcu_boost_start / _end            0x922a38d6
 *   sync_rcu_wait_start / _end        0x389e96a6
 *
 * TRACE_INCLUDE_PATH is defined only in the CREATE_TRACE_POINTS pass, which is
 * the stock trace/hooks hook-header idiom (see hooks/mm.h): in ordinary translation
 * units <trace/define_trace.h> is a no-op, so nothing can leak into the file's
 * own trace/events headers (mm/filemap.c, kernel/fork.c include their events
 * header first and #undef CREATE_TRACE_POINTS afterwards); during the defining
 * pass define_trace.h undefines TRACE_INCLUDE_PATH again via
 * UNDEF_TRACE_INCLUDE_PATH.
 */
#undef TRACE_SYSTEM
#define TRACE_SYSTEM dash_os4_stub

#ifdef CREATE_TRACE_POINTS
#define TRACE_INCLUDE_PATH trace/hooks
#define UNDEF_TRACE_INCLUDE_PATH
#endif
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

/* page-cache compression: node_cache.ko (F2FS node cache) */
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

/* Compile-time pin on the prototypes above (and on the KCFI hashes of the
 * stock modules). Keep in sync with the DECLARE_HOOKs. */
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
