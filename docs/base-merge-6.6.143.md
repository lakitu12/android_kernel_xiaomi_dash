# 基底同步：ACK 6.6.118 → 6.6.143

`main` 把 ACK 基底从 `android15-6.6-2026-01_r1`（Linux 6.6.118）升到
`android15-6.6-2026-10_r3`（Linux 6.6.143）。小米 `dash-w-oss` 的 vendor 增量与树内
delta 通过三方合并保留。

## 为什么是 2026-10_r3

`android15-6.6` 分支按季度发 tag（2026-01 / 04 / 07 / 10），每个季度 tag 之后还会有若干
`_rN` 背补丁。2026-10_r3 是这条分支上最新的 tag，对应 Linux 6.6.143。

设备 stock 仍是 6.6.118（`6.6.118-android15-8-gc44b714366cc-abogki519650608-4k`），
MTK 的 vendor 模块是对那棵树编译的。这次同步只换上游源码基底；KMI 导出集仍由
`android/abi_gki_aarch64_dash_os4` 白名单按 OS4 模块的 3652 个符号维护。

## 做法：树快照提交 + merge

`kernel/common` 的 refs 广告约 55 MB，`git fetch` 在本机卡在协商阶段不返回，所以这次
用 tag 的 tree 归档构造上游快照：

```bash
curl -L -o ack-143.tar.gz \
  'https://android.googlesource.com/kernel/common/+archive/refs/tags/android15-6.6-2026-10_r3.tar.gz'
mkdir ack-143 && tar xzf ack-143.tar.gz -C ack-143

git checkout -b upstream/ack-2026-10 597ea935b      # 2026-01 基底提交
rsync -a --delete --exclude=.git --exclude=.github --exclude=docs ack-143/ ./
git add -A -- . ':(exclude).github' ':(exclude)docs'
git commit -m "upstream: ACK android15-6.6-2026-10_r3 (Linux 6.6.143)"

git checkout main
git merge --no-ff upstream/ack-2026-10
```

上游快照提交挂在 2026-01 的 ACK 提交上，merge base 自动落在那里，合并出来就是
118→143 的净变化。与 6.6.118 那次一样，ACK 侧 118→143 的逐提交历史没有进仓库，
只有树快照；需要逐提交历史时另外拉 `kernel/common`。

## 冲突（9 个）

原则不变：MTK 的 vendor 改动保留，上游修复合入；两边都「加」的取并集。

| 文件 | 取舍 |
|---|---|
| `drivers/android/vendor_hooks.c`、`kernel/fork.c` | include 取并集 |
| `block/bio.c` | 取上游：`bio_add_page()` 新增 `zone_device_pages_compatible()` 检查 |
| `include/trace/hooks/blk.h` | 取上游：`bio_add_page_merge_bypass` 的定义被挪到 `struct request` 之后 |
| `fs/super.c`、`mm/filemap.c`、`mm/vmscan.c` | 取上游（只剩空行差异） |
| `android/abi_gki_aarch64_xiaomi` | 取上游（新增 mi_sched / xr-qi 等符号） |
| `tools/testing/selftests/kvm/Makefile` | 保留上游版本（此前的合并误删了它） |

## 13 个 OS4 hook 已进 ACK

2026-10 的 ACK 树自带全部 13 个 `android_vh_*`（`vmscan.h`、`mm.h`、`fs.h`、`fuse.h`、
`sched.h`、`dtask.h`、`rcu.h`），`TP_PROTO` 与原 stock Image 的 KCFI 哈希一致。因此：

- 删除 `include/trace/hooks/dash_os4_stub.h`；
- `vendor_hooks.c` 里对应的 11 个 export 删掉（ACK 自己导出）；
- `android_vh_mmap_lock_init/_free` 仍从 `drivers/android/dash_os4_decl_exports.c`
  导出——只有「只声明 tracepoint、没有 `CREATE_TRACE_POINTS`」的 TU 才能算出 stock 的
  genksyms CRC，原因见 [in-tree-deltas.md](in-tree-deltas.md#modversions-crc为什么只有两个-hook-对不上)。

调用点也以 stock 反汇编为准做了去重。合并后 ACK 与本地各有一份调用的位置有 4 处，
逐一用 stock ELF（`vmlinux-to-elf` 还原的 `stock_vmlinux.elf`）核对：

- `rcu_boost_start`：在 `rt_mutex_lock` 之前（`rcu_boost_kthread+0x2d4` 的冷路径跳回
  `rt_mutex_lock`）；
- `rcu_boost_end`：在 `rt_mutex_lock` 与 `rt_mutex_unlock` 之间（`+0x33c` 跳回
  `rt_mutex_unlock`），不是 unlock 之后；
- `fuse_request_fetch`：`spin_unlock(&fiq->lock)` 之后；
- `percpu_rwsem_init`：`__percpu_init_rwsem()` 末尾、`return 0` 之前。

这四处与 ACK 的布局一致，删掉本地重复调用。`verify-tree.sh` 现在断言 13 个 hook 的
定义、export 分工和调用点都还在。

## 合并时踩到的两个重复导出

1. `android_vh_bio_add_page_merge_bypass`：小米树与 ACK 143 都导出了一条，git 把两条都留下，
   编到 `vendor_hooks.c` 才报 `__export_symbol_... is already defined`。删掉一条。
   （6.6.118 那次是同名的 `android_vh_mm_free_page`，见 base-merge-6.6.118.md。）
2. `android_vh_mmap_lock_init/_free`：ACK 143 新把它们加进 `kernel/sched/vendor_hooks.c`，
   而那个 TU 有 `CREATE_TRACE_POINTS`，从那里导出算出的 genksyms CRC 不是 stock 的
   `0x615d194b` / `0xa301bcc9`，`os_cpu_qi.ko` 会以 `disagrees about version of symbol`
   拒载。这两条从 `kernel/sched/vendor_hooks.c` 删掉，仍由 `dash_os4_decl_exports.c`
   导出。`verify-tree.sh` 现在对两个 TU 都做反向断言，并检查 `drivers/android` 下的
   重复导出。

## 对 stock 模块的 ABI 影响（实测）

stock OS4 的 638 个 `.ko` 是对 6.6.118 编的，`CONFIG_MODVERSIONS=y` 下每个模块的
`__versions` 段都记着它期望的符号 CRC。把两棵树的 `__crc_*` 全表提出来对比：

| 项 | 6.6.118 | 6.6.143 |
|---|---|---|
| vmlinux 导出 CRC 条目 | 16438 | 16754 |
| 638 个模块依赖的符号（去重） | 6815 | 6815 |
| 这些符号里 CRC 与模块期望相符的 | 896 | 896 |
| 与 6.6.118 相比 CRC 变化的符号 | — | 121 |
| 变化的符号里被模块依赖的 | — | **0** |

121 个变化的符号集中在 6.6.143 改过结构体的子系统：`jbd2_*`（`journal_s`）、`nvme_*`
（`struct nvme_ctrl`）、`nf_conncount_*` / `nf_queue_*`、`dm_exception_store_*`、
`scsi_eh_prep_cmnd`、`security_locked_down` 等。这些在本设备的 638 个模块里都没有引用。
143 另新增 330 个导出（swap/调度类 vendor hook），少了 14 个（`strp_*`、`nf_conncount_add`
等），也都不在模块依赖集合里。

也就是说：**升级本身不给 stock 模块引入新的 CRC 失配**。

上面那张表里「896 相符」这个绝对值偏低，是本地 plain make 配置与 MTK 编 stock 时用的
配置不同造成的（`SYSVIPC` 等我们有意加的项会改 `task_struct` 相关符号的 CRC），
两棵树完全一样，所以不影响相对结论。绝对一致性要在 CI 的 kleaf 产物上量，或者直接
上机看模块加载数。

## 验证

- `bash .github/scripts/verify-tree.sh .` 通过；
- 全树无冲突 marker；
- plain make（clang 22）+ `gki_defconfig` + `dash_gki.fragment` 编出 `Image`（6.6.143-4k）；
- 上面那轮 ABI 对比：118 与 143 用同一套配置各编一次，对比 16424 个共有导出符号。

还没做的：CI（kleaf）构建、KMI missing=0 / KCFI 哈希 / 版本串的二进制门禁、上机启动与
模块加载数。