// SPDX-License-Identifier: GPL-2.0
/*
 * boot_diag - DIAGNOSTIC ONLY.
 *
 * Armed by the kernel cmdline token "bootdiag=flash".  A small kthread keeps
 * persisting the newest slice of the kernel log into two alternating 1MB slots
 * of the GPT partition named "oops" (16MB flash, never holds anything
 * critical), once per second, starting 200ms after the core initcalls.
 *
 * Whatever the newest complete slot holds is the state of the machine right
 * before it died: no init, no /dev, no mtdoops and no console needed.  A hang
 * that happens after the first write therefore always leaves evidence behind,
 * and a hang that leaves nothing at all means the kernel broke before the
 * recorder thread ever got to run.
 *
 * Slot layout (slot i at SLOT_BASE + i * SLOT_STRIDE):
 *   0x0000 .. 0x1ff    header (text, written first, carries seq + uptime)
 *   0x1000 .. 0x81000  newest DIAG_CAP bytes of the log, linearised
 */
#include <linux/init.h>
#include <linux/kthread.h>
#include <linux/delay.h>
#include <linux/sched.h>
#include <linux/sched/debug.h>
#include <linux/kmsg_dump.h>
#include <linux/vmalloc.h>
#include <linux/blkdev.h>
#include <linux/buffer_head.h>
#include <linux/device/class.h>
#include <linux/ktime.h>
#include <linux/string.h>
#include <linux/kernel.h>

#define DIAG_PART	"sdc92"		/* /dev/block/by-name/oops */
#define SLOT_BASE	(8u << 20)	/* keep clear of the 4MB AEE report @0 */
#define SLOT_STRIDE	(4u << 20)	/* slot0 @8MB, slot1 @12MB (2MB mtd pages) */
#define DIAG_CAP	(512u << 10)	/* newest 512KB of the ring */
#define DIAG_ITERS	240		/* ~4 minutes of 1s cadence */

static char *diag_ring;		/* DIAG_CAP ring buffer, newest bytes */
static char *diag_lin;		/* DIAG_CAP chronological copy to write out */
static char diag_line[8192];
static size_t diag_total;

/* Walk the kmsg iterator and keep the newest DIAG_CAP bytes in diag_ring. */
static void diag_capture_kmsg(void)
{
	struct kmsg_dump_iter iter;
	size_t len;

	kmsg_dump_rewind(&iter);
	for (;;) {
		len = 0;
		if (!kmsg_dump_get_line(&iter, false, diag_line,
					sizeof(diag_line), &len))
			break;
		if (!len)
			break;
		if (len >= DIAG_CAP) {
			memcpy(diag_ring, diag_line + len - DIAG_CAP, DIAG_CAP);
			diag_total += len;
			continue;
		}
		{
			size_t off = diag_total % DIAG_CAP;
			size_t first = min(len, DIAG_CAP - off);

			memcpy(diag_ring + off, diag_line, first);
			if (first < len)
				memcpy(diag_ring, diag_line + first, len - first);
		}
		diag_total += len;
	}
}

/* Copy the ring into diag_lin in chronological order; returns bytes to write. */
static size_t diag_linearise(void)
{
	size_t n = diag_total < DIAG_CAP ? diag_total : DIAG_CAP;

	if (diag_total <= DIAG_CAP) {
		memcpy(diag_lin, diag_ring, n);
	} else {
		size_t start = diag_total % DIAG_CAP;
		size_t first = DIAG_CAP - start;

		memcpy(diag_lin, diag_ring + start, first);
		memcpy(diag_lin + first, diag_ring, start);
	}
	return n;
}

/* Byte-offset write straight into the partition, no /dev, no mount. */
static int diag_flash_write(const char *buf, size_t len, size_t part_off)
{
	const size_t bs = 4096;
	struct bdev_handle *h;
	struct buffer_head *bh;
	struct device *d;
	size_t off = 0, n;
	unsigned int blkbits;
	dev_t devt;
	int ret = 0;

	d = class_find_device_by_name(&block_class, DIAG_PART);
	if (!d) {
		pr_err("bootdiag: partition %s not found\n", DIAG_PART);
		return -ENODEV;
	}
	devt = d->devt;
	put_device(d);

	h = bdev_open_by_dev(devt, BLK_OPEN_READ | BLK_OPEN_WRITE, NULL, NULL);
	if (IS_ERR(h)) {
		pr_err("bootdiag: bdev_open_by_dev failed %ld\n", PTR_ERR(h));
		return PTR_ERR(h);
	}
	/* __getblk() block numbers are 1 << bd_inode->i_blkbits bytes each. */
	blkbits = h->bdev->bd_inode->i_blkbits;

	while (off < len) {
		n = min_t(size_t, len - off, bs);
		bh = __getblk(h->bdev, (part_off + off) >> blkbits, bs);
		if (!bh) {
			ret = -ENOMEM;
			break;
		}
		memcpy(bh->b_data, buf + off, n);
		mark_buffer_dirty(bh);
		ret = sync_dirty_buffer(bh);
		brelse(bh);
		if (ret)
			break;
		off += n;
	}
	bdev_release(h);
	pr_info("bootdiag: wrote %zu/%zu @0x%zx (ret %d)\n", off, len,
		part_off, ret);
	return ret;
}

static int diag_write_slot(unsigned int slot, unsigned long seq, size_t n)
{
	size_t base = SLOT_BASE + slot * SLOT_STRIDE;
	struct timespec64 ts;
	char hdr[256];
	int hl, ret;

	ktime_get_boottime_ts64(&ts);
	hl = snprintf(hdr, sizeof(hdr),
		      "BOOTDIAG3 seq=%lu slot=%u uptime=%lld.%06ld bytes=%zu\n",
		      seq, slot, (long long)ts.tv_sec, ts.tv_nsec / 1000, n);
	/* header first: a live slot is identifiable even if the tail is torn */
	ret = diag_flash_write(hdr, hl, base);
	if (ret)
		return ret;
	return diag_flash_write(diag_lin, n, base + 4096);
}

static int diag_kthread(void *unused)
{
	unsigned int i;
	size_t n;
	int ret;

	msleep(200);
	for (i = 0; i < DIAG_ITERS; i++) {
		if (kthread_should_stop())
			break;
		diag_capture_kmsg();
		n = diag_linearise();
		ret = diag_write_slot(i & 1, i + 1, n);
		pr_info("bootdiag: slot %u seq %u wrote %zu bytes (ret %d)\n",
			i & 1, i + 1, n, ret);
		ssleep(1);
	}
	for (;;)
		ssleep(3600);
	return 0;
}

static int __init diag_late(void)
{
	pr_info("bootdiag: kernel initcalls completed (about to run /init)\n");
	return 0;
}
late_initcall(diag_late);

static int __init diag_init(void)
{
	if (!saved_command_line || !strstr(saved_command_line, "bootdiag=flash"))
		return 0;
	diag_ring = vzalloc(DIAG_CAP);
	diag_lin = vzalloc(DIAG_CAP);
	if (!diag_ring || !diag_lin) {
		vfree(diag_ring);
		vfree(diag_lin);
		diag_ring = NULL;
		diag_lin = NULL;
		return -ENOMEM;
	}
	pr_emerg("bootdiag: recorder armed (1s cadence, slots @%uMB/%uMB)\n",
		 SLOT_BASE >> 20, (SLOT_BASE + SLOT_STRIDE) >> 20);
	if (IS_ERR(kthread_run(diag_kthread, NULL, "bootdiag"))) {
		pr_err("bootdiag: kthread_run failed\n");
		vfree(diag_ring);
		vfree(diag_lin);
		diag_ring = NULL;
		diag_lin = NULL;
	}
	return 0;
}
core_initcall(diag_init);
