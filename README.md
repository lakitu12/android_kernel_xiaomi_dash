# kernel_dash_droidspaces

GKI android15-6.6 自定义内核 — Redmi Turbo 5 Max (dash, MT6991Z, 天玑 9500s)。

DroidSpaces（宿主容器）+ SukiSU Ultra（KPM + SUSFS）。仓库结构/方法论复用
[kernel_marble_droidspaces](https://github.com/lakitu12/kernel_marble_droidspaces)
（marble 5.10.236 同配方已实机验证 7 轮 CI + 开机）。

## Stock 基线（实机 boot.img 实测，2026-08-30）

| 项 | 值 | 来源 |
|---|---|---|
| 内核版本 | `6.6.118-android15-8-gc44b714366cc-abogki519650608-4k` | extract-ikconfig + strings，本地 stock boot.img |
| GKI 代 | **GKI 3.0**（boot.img header v4, RAMDISK_SZ=0 → boot 仅含内核, kernel LZ4；generic ramdisk 在 **init_boot** 分区） | magiskboot 头解析 |
| `abogki` 前缀 | MTK 用 AOSP GKI 产物做的 fork 构建 | 版本字符串 |
| KMI | `android15-8`（KMI generation 8） | 版本字符串 |
| page size | 4K（`CONFIG_ARM64_PAGE_SHIFT=12`，`-4k` 后缀） | ikconfig |
| LTO | **`CONFIG_LTO_NONE=y`**（与 marble 的 LTO_FULL 不同！） | ikconfig |
| CFI | `CONFIG_CFI_CLANG=y` | ikconfig |
| MODVERSIONS | y + `MODULE_SIG_PROTECT=y` | ikconfig |
| ANDROID_KABI | `ANDROID_KABI_RESERVE=y`（kABI 补丁有保留区可用） | ikconfig |
| SCSS | `CONFIG_SHADOW_CALL_STACK=y` | ikconfig |
| 源码 tag 对应 | `android15-6.6-2026-01_r1`（Makefile SUBLEVEL=118 已核实） | AOSP common |

`c44b714366cc` 本身不在 AOSP common 上（MTK fork 内部提交），但 base tag 锁
`android15-6.6-2026-01_r1`（同为 6.6.118）。

## Workflow

`.github/workflows/build.yml`（marble 模板改造，差异点见文件内注释）：

- repo sync 钉 `common-android15-6.6-2026-01` + local_manifest 锁 tag
  `android15-6.6-2026-01_r1`，SUBLEVEL=118 门禁
- DroidSpaces kABI 补丁 `001.GKI-below-6.12-fix_sysvipc_kabi_6_7_8.patch`
  （6.6 属 below-6.12；无 002 MQUEUE 补丁——那是 ≤5.10 专属）
- gki_defconfig：官方 GKI-safe 集 + KPROBES/KALLSYMS；**LTO/CFI 保持 stock**
- 版本尾巴：`.scmversion` 在 6.x 已死（setlocalversion 不再读）→ kleaf 无 stamp
  构建时 `build/kleaf/impl/stamp.bzl` 生成 literal `-maybe-dirty`，workflow 直接
  sed 该文件为 `-droidspaces-lakitu` → `6.6.118-android15-8-droidspaces-lakitu`
  （KMI 尾巴 `-android15-8` 由同一文件携带；`CONFIG_LOCALVERSION` 反而会拼在
  文件内容之后，不用）
- SukiSU builtin 分支（SUSFS 符号必需）+ susfs4ksu `gki-android15-6.6`
  分支补丁（已核实存在）
- AK3：Numbersf 大写变量基底；dash boot 仅含 kernel（generic ramdisk 在 init_boot、
  vendor ramdisk 在 vendor_boot）→ `flash_boot` 只换内核、init_boot/vendor_boot 不动
- 产物：matrix `ksu` / `bypass` 双变体，Image + AK3 zip

## KPM 与 KernelPatch 预补丁

`CONFIG_KPM=y` **只编出一座桥**，不装 loader：`kernel/extension/kpm.c` 把 KPM
能力位设成 `sukisu_kpm_bridge(SUKISU_KPM_PROBE) == SUKISU_KPM_ABI_VERSION`，而
bridge 是拿魔法值去调 `__arm64_sys_truncate`（KernelPatch 复用 syscall 45 的
supercall 入口）。内核里没有 KP 时 probe 返回 `-EOPNOTSUPP` → 管理器 KPM 能力位
=0（dmesg `registered handler for kpm (id=0, caps=0x0, …)`）、`ksud kpm` 一律
`os error 95`。换句话说：**不打 KP，KPM 永远不可用，跟 SukiSU 配置无关**。

workflow 因此在 ksu 变体上多一步预补丁（`workflow_dispatch` 输入 `kpm_patch`，
默认 `on`）：

| 项 | 取值 |
|---|---|
| kpimg | `ShirkNeko/SukiSU_patch` 仓钉 commit 拉取，断言 sha256（与管理器 APK 内 `assets/kpm/kpimg` 逐字节一致） |
| kptools | 从 `bmax121/KernelPatch` 钉 commit 现建（host 工具，需 cmake + zlib） |
| superkey | 每次构建随机，`-S` 只把 hash 写进镜像；KPM 走 supercall syscall，不依赖它 |
| 门禁 | `kptools -l` 必须 `patched=true`；产物后缀带 `-KP` 才代表 KPM 真可用 |
| 跳过条件 | `ksu_opts` 含 `no_kpm`（没有桥，打了也没用） |

实测（dash，6.6.118，KP e00）：预补丁后 17–23s 进桌面，583 模块、root、
`os_cpu_qi`/`node_cache` 全正常；`ksud kpm load/unload/list/num/version` 全部
`rc=0`，用 KP 自带 `demo-hello` 验证过 `load_module_ex: [kpm-hello-demo] succeed`。
注意 KP 会在 boot 早期跑自己的初始化代码，且 superkey（或 hash）进 boot.img。

## 首刷安全规程（A/B 守护，同 marble）

```bash
fastboot getvar current-slot           # 记住当前槽
fastboot flash boot_<当前槽> boot.img   # 只刷当前槽
# 开机验证 uname -r；异常时 fastboot --set-active <另一槽> 回滚
```

vbmeta：解锁后镜像未签名，若卡第一屏 →
`fastboot flash vbmeta_<槽> --disable-verity --disable-verification vbmeta.img`。

## DroidSpaces 要求核查（stock → 目标）

`droidspaces check` 致命项：PID_NS/MNT/UTS/IPC_NS/CGROUP_DEVICE/DEVTMPFS。
stock 缺失项（ikconfig 实测）：SYSVIPC、POSIX_MQUEUE、IPC_NS、PID_NS、DEVTMPFS、
USER_NS、TMPFS_XATTR/POSIX_ACL、NETFILTER_XT_MATCH_ADDRTYPE、IP_SET —
全部由本内核补齐；UTS_NS/OVERLAY_FS/SECCOMP/VETH/CGROUP_FREEZER/MEMCG stock 已有。
