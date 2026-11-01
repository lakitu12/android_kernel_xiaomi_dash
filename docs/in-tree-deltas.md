# 树内 delta

2026-10-30 之前，dash 的内核改动以 `patches/` 目录维护、CI 构建时应用；之后改成直接作为
提交烘进树里（`git log --oneline 537ebbfb..HEAD`），`patches/` 目录和补丁应用器都已删除。
下面记录每个改动为什么这么做。

| 提交 | 内容 |
|---|---|
| `2cefe8eac` | DroidSpaces kABI padding |
| `4513908e6` | 13 个 OS4 vendor hook |
| `5a0528e72` | trusty-rescue + `kvm-arm.mode=nvhe` |
| `5846e03c7` | pid 空间钳到 32768 |
| — | `arch/arm64/configs/dash_gki.fragment` |

## kABI padding

`sysv_sem` / `sysv_shm` 挪进 `ANDROID_KABI_RESERVE(6..8)`，于是开 `CONFIG_SYSVIPC` 也不改
`task_struct` 布局，stock 编的 vendor 模块照旧能加载。做法与 marble 一致。

## OS4 vendor hook（13 个）

dash OS4 的 `node_cache.ko` 要 4 个 `android_vh_*` tracepoint，`os_cpu_qi.ko` 要 9 个，
AOSP GKI 6.6 里没有这些定义。

`TP_PROTO` 不能改。`CONFIG_CFI_CLANG=y` 下 `__traceiter_*` 会核对探针类型哈希，与原厂不一致
会在 hook 第一次触发时 `brk #0x8228`。现有原型是用 `clang -fsanitize=kcfi` 复算、与 stock
内核的立即数逐位对齐得到的；调用点位置由 stock Image 反汇编里每一条 `bl __traceiter_*`
定位。构建后 `.github/scripts/verify-os4-kcfi.py` 再核对一次哈希。

## trusty-rescue

gz / Trusty 固件被抹除（给内核 EL2 跑 pKVM）之后，`gz_trusty_mod` 的 SMC 握手失败，
`/trusty/trusty-virtio` 不生成，secure-cmdq mailbox → imgsys / IMGSCP 相机链永久 defer，
`camerahalserver` 崩溃循环。

驱动在 3 秒后起 delayed work，轮询三个条件——`trusty-virtio` 驱动已注册、对应 platform
device 缺失、`/trusty` 父设备未绑定——连续成立 15 秒才动作，总窗口 90 秒：pin 住
`gz_virtio_mod` 防 rmmod 双注销，摘掉 `trusty_virtio_driver`（它的 probe 会对 NULL 解引用
直接 ipanic），再造一个 `trusty-virtio` marker 设备让 secure-cmdq 的 probe 能过。
gz 正常在位时是 no-op。

配套把 `CONFIG_CMDLINE` 里的 `kvm-arm.mode=protected` 改成 `nvhe`。gz 在位时 LK 把内核起在
EL1，KVM 初始化整体跳过，这个字符串无害。

## pid 钳制

`PID_MAX_LIMIT` 与 `pid_max_max` 都钳到 32768，让 0x8000 掩码类 bug 不可达（stock 的 id
空间约 8% 会踩到）。两处都要改：头文件宏可被重新定义，`kernel/pid.c` 的 `pid_max_max`
才是硬钳制。

## modversions CRC：为什么只有两个 hook 对不上

13 个 hook 里，`android_vh_mmap_lock_init/_free` 的 `__tracepoint_*` genksyms CRC 与 stock
不一致，其余 11 个以及全部 `__traceiter_*` / `__SCK__*` 都逐位相同（stock 与自编 Image 的
8988 个公共导出符号里只有这 2 个不同）。后果是 `os_cpu_qi.ko` 被以
`disagrees about version of symbol ... (err -22)` 拒载，连带 `os_cpu_qs` / `task_turbo` /
`mi_game` / `cpq` / `mi_reclaim` 整条 QoS 模块链起不来（实测 556 → 584 个模块）。

genksyms 对 `__tracepoint_X` 的 CRC 取自 EXPORT 语句所见的声明文本：若该 TU 里还见过
`DEFINE_TRACE_FN` 的定义（带 `__used __section("__tracepoints")` 属性 tokens），CRC 会把
属性算进去；只见过 `extern struct tracepoint __tracepoint_X;` 则不算。stock 把这两个 hook
的 EXPORT 放在一个只声明 tracepoint、没有 `CREATE_TRACE_POINTS` 的 TU 里，我们原来把 13 个
export 全塞在 `drivers/android/vendor_hooks.c`（该 TU 有 `CREATE_TRACE_POINTS`），所以只有
这两个的 CRC 变了。

修法是照抄 stock 的布局：新增 `drivers/android/dash_os4_decl_exports.c`，只
`#include <linux/tracepoint.h>` + stub 头 + 两条 `EXPORT_TRACEPOINT_SYMBOL_GPL`，把这两个
export 从 `vendor_hooks.c` 移过去。`__tracepoint_*` 对象仍由 `vendor_hooks.c` 的
`CREATE_TRACE_POINTS` 定义。这样编出来的 Image 里两个 CRC 是 `0x615d194b` / `0xa301bcc9`，
`os_cpu_qi.ko` 直接加载。

`.github/scripts/patch-kcrctab.py` 保留为诊断工具（CI 不再调用）：先全量 diff kcrctab 定位
符号，再用它临时钉值验证是不是这个 CRC 的问题。

## 合并小米树时要注意的两处

- `drivers/Makefile` 末尾是 MTK 的 `include $(srctree)/$(KCONFIG_EXT_PREFIX)Makefile.ext`，
  往这个文件加内容时不要锚在末尾，锚在那行 include 之前。
- 小米树自带的 `EXPORT_TRACEPOINT_SYMBOL_GPL(android_vh_mm_free_page)` 与 AOSP 118 就地
  新增的同名 export 会被 git 合并成两条，报 `__export_symbol_... is already defined`，
  注意去重。
