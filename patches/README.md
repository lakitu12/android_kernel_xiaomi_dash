# patches/ — 我们对内核源树的全部改动

dash 自编内核所需的所有内核侧改动都集中在这里，以**标准 unified diff** 维护，由
[`../.github/scripts/apply-patches.py`](../.github/scripts/apply-patches.py) 统一应用。

基底是仓库根目录的内核树：小米 `dash-w-oss`（6.6.89）三方合并 ACK
`android15-6.6-2026-01_r1`（6.6.118）的干净树——补丁不预置进树，仍是唯一的
「我方 delta」载体（见 [`../docs/base-merge-6.6.118.md`](../docs/base-merge-6.6.118.md)）。

```
patches/
├── trusty-rescue/        gz 被抹除（nvhe/pKVM）启动时的相机链自救驱动
├── os4-vendor-hooks/     dash OS4 厂商模块需要的 13 个 MTK vendor hook
└── pid-max-clamp/        pid 空间钳到 32768（MKP 0x8000 类 bug 的规避）
```

CI 里只有一步 `Apply maintenance patches`，它调用
[`apply-tree-patches.sh`](../.github/scripts/apply-tree-patches.sh)：先应用本目录
全部补丁，再逐条自检（每个 hook 的 `DECLARE_HOOK` / 导出 / 调用点、rescue 的
Kconfig/Makefile 挂钩与 nvhe cmdline、pid_max 的两处钳制）。少一条就 fail。

## 为什么用补丁而不是脚本

* 整个 delta 一屏可读、可 review、可 diff、可回滚；
* 应用器只做 `git apply` / `patch`，不做字符串手术；
* 上游漂移时补丁会**干净地失败**，而不是「悄悄插到错误位置还编译通过」。

代价是上下文变了要重新生成补丁——这是有意的取舍（宁失败，不静默错）。

## 应用器行为

```
apply-patches.py --tree <kernel/common> --patches <dir> [--check]
```

1. `git apply --check`（精确）
2. `git apply --check --ignore-whitespace`（行尾空白差异）
3. `patch -p1 --dry-run -F2`（轻微偏移）
4. 反向可应用 → 视为「已打过」，跳过（重跑幂等）
5. 否则失败并打印 `git apply -v` 的排查命令

补丁按路径排序应用，series 之间相互独立。

**注意应用时机**：本目录在 CI 里位于「版本串修正」之后，而该步骤会往
`arch/arm64/configs/gki_defconfig` 末尾追加 `# CONFIG_LOCALVERSION_AUTO is not set`。
所以补丁的 hunk 不要锚在文件末尾（0003 最初就是 end-of-file hunk，第一次 CI
必然失败），锚到改动点附近的稳定上下文（如 `CONFIG_CMDLINE_EXTEND=y` 后面）。
依此类推：任何「前置步骤会改的文件」都要按**前置步骤之后**的状态来生成补丁。

## 上机单变量开关（HOOK_CALL_SITES）

2026-10-29 教训：全量 call site 的内核在真机上 **bootloop**，而当时 missing=0、
13/13 KCFI 哈希全对、payload 也一致——**离线门禁证明不了调用点位置/锁上下文在真机安全**。
所以 call site 要一组一组上机验证，开关在 `apply-tree-patches.sh`：

| 值 | 含义 |
|---|---|
| `full`（默认，push 构建走这个） | 13 个 hook 定义+导出+全部调用点 |
| `none` | 只有定义+导出，没有任何调用点（先确认这种能进系统） |
| `0004` / `0004,0005` … | 只上指定分组的调用点，其余跳过 |

分组对应关系（补丁号 → 文件 → hook）：

```
0004 mm/vmscan      remove_mapping, remove_mapping_failed
0005 mm/filemap     filemap_get_folio_end
0006 fs/super       put_super
0007 fs/fuse        fuse_request_end_ext, fuse_request_fetch
0008 kernel/fork    mmap_lock_init, mmap_lock_free
0009 percpu-rwsem   percpu_rwsem_init
0010 rcu            rcu_boost_start/end, sync_rcu_wait_start/end
```

CI 里用 `workflow_dispatch` 的 `hook_call_sites` 输入选择；非 `full` 的产物文件名带
`-SITES<组号>` 后缀，避免和全量版混淆。

另有 `no_lz4_export` 输入（`0`/`1`）：`1` 时把 `LZ4_compress_default` 从 KMI 白名单里删掉。
`node_cache.ko` 需要 4 个 hook **加** LZ4，所以它会退化成「加载失败」（等同原厂行为）；
`os_cpu_qi.ko` 只需要 9 个 QoS hook，仍然能加载。用它在不改源码的前提下把两个模块分开。
产物带 `-NOLZ4` 后缀。

另有 `os4_hooks` 输入（`on`/`off`）：`off` 时整个 os4-vendor-hooks series 都不打，
树回到 stock 状态——`node_cache.ko`/`os_cpu_qi.ko` 会像原厂内核一样**加载失败**。
这是隔离「模块现在能加载了」与「我们改的其它东西」的控制组（2026-10-29：
`none` 版无任何调用点仍 bootloop，说明触发点不是调用点，而是模块能加载之后的行为）。
产物带 `-NOHOOKS` 后缀。`apply-tree-patches.sh` 的自检
会按选择断言：选中的组必须**有**调用点，未选中的组必须**没有**。

## 各 series 的前置知识

### trusty-rescue
gz/Trusty 固件被抹除后（给内核 EL2 跑 pKVM），`gz_trusty_mod` 的 SMC 握手失败，
`/trusty/trusty-virtio` 不会生成，secure-cmdq mailbox → imgsys/IMGSCP 相机链永久
defer，`camerahalserver` 崩溃循环。这个驱动做三腿指纹自检（driver 已注册 / device
缺失 / 父设备未绑定），持续成立才动作，健康 gz 启动下是 no-op。
配套把 `CONFIG_CMDLINE` 的 `kvm-arm.mode=protected` 改成 `nvhe`。

### os4-vendor-hooks
13 个 `android_vh_*` tracepoint 在 AOSP GKI 6.6 里不存在，但 dash OS4 的
`node_cache.ko`（4 个）与 `os_cpu_qi.ko`（9 个）要 probe 它们。
**TP_PROTO 不能改**：`CONFIG_CFI_CLANG=y` 下 `__traceiter_*` 会核对探针类型哈希，
与原厂不一致会在 hook 首次触发时 `brk #0x8228`。现有原型是用
`clang -fsanitize=kcfi` 复算、与 stock 内核立即数逐位对齐得到的；调用点位置则由
stock Image 反汇编里每一条 `bl __traceiter_*` 定位。构建后
[`verify-os4-kcfi.py`](../.github/scripts/verify-os4-kcfi.py) 再验一次哈希。
细节见 `~/下载/dash-os4/os4-hooks-callsite-map.md`。

### pid-max-clamp
`PID_MAX_LIMIT` 与 `pid_max_max` 都钳到 32768，使 0x8000 掩码类 bug 不可达
（dash stock 的 id 空间约 8% 会踩到）。改两处是因为头文件宏可被重新定义，
`kernel/pid.c` 的 `pid_max_max` 是硬钳制。

## 重新生成

基底是仓库根目录的内核树（小米 `dash-w-oss` 三方合并 ACK `android15-6.6-2026-01_r1`
= 6.6.118，见 [`../docs/base-merge-6.6.118.md`](../docs/base-merge-6.6.118.md)），
不再是 repo sync 出来的 AOSP 树。改完补丁内容后：

```bash
# 在干净基底上应用本目录全部补丁，得到 after 树（--check 只验不落地）
python3 .github/scripts/apply-patches.py --tree . --patches patches
# 生成某个文件的 diff：在 kernel/ 里改完，回到仓库根取「相对 kernel/」的 diff
git diff --no-color -- mm/vmscan.c \
  | sed 's#^--- a/#--- a/#;s#^+++ b/#+++ b/#' \
  > patches/os4-vendor-hooks/0004-mm-vmscan-add-remove-mapping-hooks.patch
```

合并到小米树后新出现的两个坑（2026-10-30）：

* `drivers/Makefile` 末尾是 MTK 的 `include $(srctree)/$(KCONFIG_EXT_PREFIX)Makefile.ext`，
  所以 `trusty-rescue/0002` 的 hunk 不能再锚在文件末尾，要锚在 `obj-$(CONFIG_S390)`
  之后、那行 include 之前（已刷新）。
* 小米树自带的 `EXPORT_TRACEPOINT_SYMBOL_GPL(android_vh_mm_free_page)` 与 AOSP 118
  就地新增的同名 export 会被 git 合并成两条 → `__export_symbol_... is already
  defined`。改树/改补丁时留意去重。
## modversions CRC：为什么只有两个 hook 对不上，以及修法

`os4-vendor-hooks` 的 13 个 hook 里，`android_vh_mmap_lock_init/_free` 两个
`__tracepoint_*` 符号的 genksyms CRC 与 stock 内核不一致（其余 11 个、以及全部
`__traceiter_*` / `__SCK__*` 的 CRC 逐位相同；2026-10-29 实测：stock 与自编 Image
的 8988 个公共导出符号里只有这 2 个不同）。后果是 `os_cpu_qi.ko` 被内核以
`disagrees about version of symbol ... (err -22)` 拒载，连带 `os_cpu_qs` /
`task_turbo` / `mi_game` / `cpq` / `mi_reclaim` 整条 QoS 模块链起不来
（实测 556 → 584 个模块）。

根因（2026-10-29 用 AOSP 6.6.118 树 + 树内 genksyms 复现，并由 CI 实测确认）：
genksyms 对 `__tracepoint_X` 的 CRC 取自 **EXPORT 语句所见的声明文本**：
若该 TU 里还见过 `DEFINE_TRACE_FN` 的定义（含
`__used __section("__tracepoints")` 属性 tokens），CRC 就把属性算进去；
若只见过 `extern struct tracepoint __tracepoint_X;`，则不算。
stock 把这两个 hook 的 EXPORT 放在一个**只声明 tracepoint 的 TU**（没有
`CREATE_TRACE_POINTS`），所以它的 CRC 是不带属性那一版；我们原来把 13 个 export
全塞在 `drivers/android/vendor_hooks.c`（该 TU 有 `CREATE_TRACE_POINTS`），于是
这 2 个 CRC 变成带属性那一版——只有这 2 个不同，正是因为只有它们的 export 位置
与 stock 不同。

修法就照抄 stock 的布局：`0002` 补丁新增 `drivers/android/dash_os4_decl_exports.c`
（只 `#include <linux/tracepoint.h>` + stub 头 + 两条 `EXPORT_TRACEPOINT_SYMBOL_GPL`，
并挂进 `drivers/android/Makefile`），把这两个 export 从 vendor_hooks.c 移过去。
`__tracepoint_*` 对象仍由 vendor_hooks.c 的 `CREATE_TRACE_POINTS` pass 定义。
CI 实测：这样编出来的 Image 里两个 CRC 就是 `0x615d194b` / `0xa301bcc9`，
os_cpu_qi.ko 直接加载，不再需要构建后钉值。

`.github/scripts/patch-kcrctab.py` 保留为**诊断/兜底工具**（CI 不再调用）：
先全量 diff kcrctab 定位是哪个符号，再用它临时钉值验证「就是这一个 CRC 的问题」。
