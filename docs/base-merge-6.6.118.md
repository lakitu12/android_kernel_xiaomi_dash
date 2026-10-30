# 基底合并：小米 dash-w-oss (6.6.89) + ACK 6.6.118

本文记录 `dash-6.6.118` 分支 `kernel/` 树是怎么来的、18 个冲突逐条怎么取舍、
本地怎么重做与验证。目的：下一次 MTK 更新 `dash-w-oss` 或 AOSP 出新月度 tag 时，
照这个流程重跑一遍即可，不用重新推演。

## 为什么是这个基底

* stock 版本串 `6.6.118-android15-8-gc44b714366cc-abogki519650608-4k`：
  `abogki` 是 MTK 用 AOSP GKI 产物做的 fork 构建 → 我们照 AOSP 编出来的内核，
  KMI 与 vendor_dlkm 的期望不是「同一个树」出来的（13 个 vendor hook 的由来）。
* 小米 `dash-w-oss` 是 MTK 放出来的对应树：`t-alps-release-v0.mp1.rc-V13.94`，
  Makefile `SUBLEVEL = 89`，与 ACK `android15-6.6-2025-06_r1` 逐文件对比只有
  104 个条目不同（≈34 个文本文件 + 3 个独有文件）——即「AOSP 6.6.89 + MTK 增量」。
* 设备跑的是 6.6.118，所以要把 89→118 的上游增量合进来 → 三方合并，
  合并基底就是 AOSP 6.6.89，这样 MTK 的增量会自动保留。

## 流程（可重跑）

```bash
export WORK=~/staging/dash-sync && mkdir -p $WORK && cd $WORK

# 1) 三份原料
curl -L -o xiaomi.tar.gz https://codeload.github.com/MiCode/Xiaomi_Kernel_OpenSource/tar.gz/refs/heads/dash-w-oss
curl -L -o aosp-89.tar.gz  https://codeload.github.com/aosp-mirror/kernel_common/tar.gz/refs/tags/android15-6.6-2025-06_r1
curl -L -o aosp-118.tar.gz https://android.googlesource.com/kernel/common/+archive/refs/tags/android15-6.6-2026-01_r1.tar.gz
mkdir -p xiaomi-dash aosp-89 aosp-118
tar xzf xiaomi.tar.gz -C xiaomi-dash --strip-components=1
tar xzf aosp-89.tar.gz -C aosp-89  --strip-components=1
tar xf  aosp-118.tar.gz -C aosp-118          # googlesource 的 archive 没有顶层目录

# 2) 三个提交，基底 = AOSP 6.6.89
git init -q -b vendor work && cd work
rsync -a --exclude=.git ../aosp-89/ ./ && git add -A && git commit -qm "import: ACK 2025-06_r1 (6.6.89)"
git checkout -q -b dash vendor
rsync -a --delete --exclude=.git ../xiaomi-dash/ ./ && git add -A && git commit -qm "vendor: Xiaomi dash-w-oss"
git checkout -q -b upstream vendor
rsync -a --delete --exclude=.git ../aosp-118/ ./ && git add -A && git commit -qm "upstream: ACK 2026-01_r1 (6.6.118)"

# 3) 合并（merge base 自动就是 aosp-89 那个提交）
git checkout -q dash
git merge --no-ff upstream      # 18 个冲突，见下表
```

## 冲突取舍（18 个文件）

原则：**MTK 的 vendor 改动保留，上游 89→118 的修复采纳**；两边都「加」的清单类
文件取并集；AOSP 重新生成的文件取 118 版。

| 文件 | 取舍 | 理由 |
|---|---|---|
| `drivers/android/vendor_hooks.c` | 并集 | MTK 的 hook 与 118 新增 hook 共存（注意：合并会静默产生**重复 EXPORT**，见下节） |
| `include/trace/hooks/{mm,blk}.h`、`kernel/sched/vendor_hooks.c` | 并集 | 同上 |
| `android/abi_gki_aarch64.stg`、`.stg.allowed_breaks`、`_sunxi`、`_vivo` | 取 118 | AOSP 按 118 树重新生成的 KMI 元数据；我们的构建不开 ABI monitoring |
| `Documentation/ABI/testing/sysfs-fs-f2fs` | 取 118 | 新增 `effective_lookup_mode` 条目 |
| `net/unix/af_unix.c` | 取 118 的那一行 | 118 给 `u->lock` 加了 lockdep class，其余 MTK 的 listener/vertex 改动自动合并 |
| `net/unix/garbage.c` | 整个取 118 | MTK 只是早一版 backport（没有 `scc_index`），118 版本是它的超集 |
| `fs/erofs/zdata.c` | 取 118 | 118 用 `z_erofs_in_atomic()` 取代了 MTK `CONFIG_MTK_F2FS_DEBUG` 分支 |
| `mm/huge_memory.c` | 取 118 的 `remap_page(folio, nr)` | 118 把 `remap_page()` 的 flags 参数删了，MTK 的 `can_split &&` 那版不再适用 |
| `mm/swap.c` | 取 118 | 118 重构成 `__page_cache_release()`，且其内部已含 MTK 补的 `folio_unqueue_deferred_split()` |
| `mm/kmemleak.c` | 取 118 | 118 的 `warn` 标志位恰好实现了 MTK 的意图（锁外打印） |
| `net/ipv4/ip_output.c` | 取 118 | 118 补上了 `rcu_read_unlock()`（MTK 侧只是删了个空行） |
| `kernel/irq/chip.c`（+ 自动合并的 `cpuhotplug.c`） | **保留 MTK** | MTK 主动回退了 managed IRQ 热插拔那组（`desc->depth` 语义），他们的 hotplug 路径依赖这个行为 |
| `drivers/usb/host/xhci.c` | 见下节 | MTK 的 `android_vh_xhci_full_reset_on_remove` 用法与 118 删掉 helper 冲突，最终取 118 的调用 |

## 合并后本地构建抓到的三个问题

1. **`xhci_handshake_check_state()` 未定义**（`drivers/usb/host/xhci.c:210`）：
   合并基底里有这个 helper，但 118 把它删了（MTK 侧没改定义处 → 删除生效），
   而 MTK 改过的调用点还在用它。118 的调用是 `xhci_handshake(...)`，直接改成
   118 版；hook `trace_android_vh_xhci_full_reset_on_remove()` 两边都有，保留不动
   （`full_reset` 变成只被取地址的变量，与 118 一致）。
   注意：cascade 会在后面几行报一堆 `-Wshift-count-overflow`（`DMA_BIT_MASK(64)`），
   那是未声明函数导致的解析恢复产物，不是真的 shift 问题。
2. **`android_vh_mm_free_page` 重复 EXPORT**：MTK 和 118 在 `vendor_hooks.c` 的
   不同位置各加了一条，git 合并成两条 → `__export_symbol_... is already defined`。
   去重（保留一条）。
3. **`android_rvh_alloc_and_link_pwqs`「重复」DECLARE 是假警报**：
   `wqlockup.h` 里 `#ifndef __GENKSYMS__` 分支（`DECLARE_RESTRICTED_HOOK`）与
   `#else` 分支（`DECLARE_HOOK`）本来就同名，不用管。

**合并后必须做全树 marker 扫描**（别只扫 `*.c/*.h`）：`android/abi_gki_aarch64_vivo`
这类 ABI 符号表里残留的 `<<<<<<< HEAD` 会让 kleaf 的 `RawKmiSymbolList`
（`flatten_symbol_list.py` 用 configparser 读符号表）直接崩：
`AttributeError: 'NoneType' object has no attribute 'append'` /
`MultilineContinuationError`。2026-10-30 的 CI run 41043522216 就是这么挂的
（18 个冲突里有 5 个是 .stg / abi 列表 / 文档，脚本只扫了代码文件 → 漏了）。

```bash
git grep -n -E '^(<<<<<<< |>>>>>>> )' -- . ':(exclude)patches'
```

体检脚本（合并后必跑，几秒钟）：

```bash
python3 - <<'EOF'
import re,glob,collections
for f in glob.glob('include/trace/hooks/*.h'):
    n=re.findall(r'DECLARE_(?:RESTRICTED_)?HOOK\((android_[a-z0-9_]+)', open(f).read())
    d=[k for k,v in collections.Counter(n).items() if v>1]
    # 同名但分别落在 __GENKSYMS__ 的两个分支里是合法的
    if d: print('CHECK DECLARE', f, d)
for f in glob.glob('**/*.c', recursive=True):
    try: s=open(f, errors='replace').read()
    except: continue
    n=re.findall(r'EXPORT_TRACEPOINT_SYMBOL_GPL\((android_[a-z0-9_]+)\)', s)
    d=[k for k,v in collections.Counter(n).items() if v>1]
    if d: print('DUP EXPORT', f, d)
EOF
```

## 验证

树在**仓库根目录**（`Makefile`/`arch/`/`drivers/`… 与 `patches/` 并列）。

补丁层（干净基底上 14 条补丁都要能 **exact `git apply`**，不能靠 fuzz）：

```bash
python3 .github/scripts/apply-patches.py --tree . --patches patches --check
```

编译层（plain make + 预编译 clang 18，等价于 CI 的 gki_defconfig 门禁；BTF 关掉
是因为主机 libbpf 在 clang 18 下会吃 `-Werror`，与内核源码无关）：

```bash
export PATH=<gki>/prebuilts/clang/host/linux-x86/clang-r510928/bin:$PATH
make O=out ARCH=arm64 LLVM=1 gki_defconfig
scripts/config --file out/.config -e SYSVIPC -e POSIX_MQUEUE -e IPC_NS -e PID_NS \
  -e DEVTMPFS -e USER_NS -e TMPFS_XATTR -e TMPFS_POSIX_ACL -e KPROBES \
  -e KALLSYMS -e KALLSYMS_ALL -d MODULE_SIG_PROTECT -d DEBUG_INFO_BTF -e LTO_NONE
make O=out ARCH=arm64 LLVM=1 olddefconfig
make O=out ARCH=arm64 LLVM=1 -j$(nproc) Image
```

2026-10-30 实测：合并后的树 + 全部 14 条补丁，`Image` 编过（30 MB），
`trusty_rescue_init`、13 个 `__traceiter_android_vh_*` 都在符号表里，
版本串 `6.6.118-...`。
