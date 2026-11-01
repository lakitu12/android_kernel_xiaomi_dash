# dash GKI 6.6.118 内核（DroidSpaces + SukiSU Ultra）

Redmi Turbo 5 Max（dash，MT6991Z，天玑 9500s）的 Android 15 GKI 内核，带 DroidSpaces
容器支持、SukiSU Ultra root（SUSFS + KPM），以及擦除 gz 之后相机链的自救驱动。

内核源码整个在仓库根目录，CI 只同步构建基建（kleaf + prebuilts），编译的就是仓库里的提交。
构建期从外部拉 SukiSU、SUSFS、KernelPatch 三样，都按 commit 钉死，不入库。

## 内容

- 基底：小米 `dash-w-oss`（MTK `t-alps-release-v0.mp1.rc-V13.94`，6.6.89 = ACK
  `android15-6.6-2025-06_r1`）三方合并 ACK `android15-6.6-2026-01_r1`（6.6.118），
  就是 stock `6.6.118-android15-8-gc44b714366cc-abogki519650608-4k` 对应的那棵树
- 树内 delta：kABI padding、13 个 OS4 vendor hook、trusty-rescue + `kvm-arm.mode=nvhe`、
  pid 钳制、`dash_gki.fragment`（见 [docs/in-tree-deltas.md](docs/in-tree-deltas.md)）
- SukiSU Ultra `builtin` + susfs4ksu `gki-android15-6.6`：构建期注入
- KernelPatch：构建期把 kpimg 预补丁进 Image，KPM 才能用

为什么用小米树而不是 AOSP ACK：stock 版本串带 `-abogki-` 前缀，说明 MTK 是在 AOSP GKI
上改过的 fork，纯 AOSP 编出来的镜像与 `vendor_dlkm` 的 KMI 对不上（当初要补 13 个
vendor hook 就是这件事的表征）。仓内树保留 MTK 的 vendor hook、ABI 符号表、`Makefile.ext`、
IRQ 回退，再把 AOSP 89→118 的修复合在上面。

## 仓库结构

| 路径 | 内容 |
|---|---|
| 仓库根 | 完整内核树（6.6.118），与 `.github/`、`docs/` 并列 |
| `arch/arm64/configs/dash_gki.fragment` | 全部配置增量，经 `BUILD.bazel` 的 `defconfig_fragments` 在 `make defconfig` 后合并；`gki_defconfig` 保持上游原样 |
| `include/linux/sched.h`、`sched/user.h` | DroidSpaces kABI padding |
| `drivers/trusty_rescue/` | gz 擦除后的相机链自救驱动 |
| `.github/scripts/verify-tree.sh` | 源码自检：基底身份、vendor 基底还在、delta 完整 |
| `.github/scripts/verify-os4-kcfi.py` | 构建后核对 13 个 OS4 hook 的 KCFI 哈希与 stock 一致 |

提交历史是真实的，不是 squash：ACK 侧 5,357 个上游 commit（6.6.89 → 6.6.118），
vendor 侧 15,627 个（MTK/AOSP 原作者），合并提交记录 18 个冲突的取舍，逐条见
[docs/base-merge-6.6.118.md](docs/base-merge-6.6.118.md)。

vendor 链是浅拉取导入的，图上有几个额外 root（commit 对象、作者、日期都是对方的）。
上游还有 1.2M commit 的 Linux 全史，故意不入库；需要时按需拉：

```bash
git fetch https://github.com/MiCode/Xiaomi_Kernel_OpenSource dash-w-oss
git fetch https://android.googlesource.com/kernel/common
```

## 构建

CI 在 push 到 `main` 或手动 `Run workflow` 时跑，矩阵两个变体：

- `ksu`：SukiSU builtin + SUSFS + KernelPatch 预补丁
- `bypass`：同一棵树，KSU 关掉

产物是 `Image` 和 AnyKernel3 zip，版本串 `6.6.118-android15-8-droidspaces-lakitu`。

CI 的构建方式：`repo sync` 只拉 `build/kernel`、prebuilts、`kernel/configs`，`kernel/common`
用 local_manifest 摘掉，再把本仓 checkout 拷成 `common/` 交给 kleaf。不要改回跟踪
`common-android15-6.6` 的 branch HEAD——它会漂，vermagic/CRC 一变，vendor 模块加载不上就是
bootloop。

本地复现照 `.github/workflows/build.yml` 走；纯编译验证可以直接用 plain make（见
[docs/base-merge-6.6.118.md](docs/base-merge-6.6.118.md) 末尾）。

## 刷入

dash 是 GKI 3.0：boot 分区只含内核，generic ramdisk 在 `init_boot`，vendor ramdisk 在
`vendor_boot`。所以 AK3 只换内核，`init_boot` / `vendor_boot` 不动。

```bash
fastboot getvar current-slot           # 记住当前槽
fastboot flash boot_<当前槽> boot.img   # 只刷当前槽
# 开机验证 uname -r；异常时 fastboot --set-active <另一槽> 回滚
```

解锁后镜像未签名，若卡在第一屏，刷 `vbmeta_<槽>`：
`fastboot flash vbmeta_<槽> --disable-verity --disable-verification vbmeta.img`。

## 注意事项

**KPM 必须预补丁 KernelPatch**。`CONFIG_KPM=y` 只编出一座桥，probe 调的是 KernelPatch 的
supercall；内核里没有 KP 时 probe 返回 `-EOPNOTSUPP`，管理器 KPM 能力位为 0，`ksud kpm`
一律 `os error 95`。workflow 在 ksu 变体上多一步 `kptools -p`，产物带 `-KP` 后缀才代表
KPM 可用。

**版本串靠改 kleaf 的 `stamp.bzl`**。`.scmversion` 在 6.x 已不再被读取，kleaf 无 stamp
构建时会输出字面量 `-maybe-dirty`；workflow 直接把该文件里的这段改成
`-droidspaces-lakitu`（KMI 尾巴 `-android15-8` 也由同一个文件携带）。不要用
`CONFIG_LOCALVERSION`，它会拼在文件内容之后。

**擦 gz 之后必须有 trusty-rescue**。gz 被抹除给内核 EL2 跑 pKVM 时，`gz_trusty_mod` 的
SMC 握手失败，`/trusty/trusty-virtio` 不生成，secure-cmdq mailbox 一路 defer，相机链
起不来、`camerahalserver` 崩溃循环。驱动在健康 gz 启动下是 no-op，配套把
`CONFIG_CMDLINE` 的 `kvm-arm.mode=protected` 改成 `nvhe`。

**DroidSpaces 的配置缺口**：stock 缺 SYSVIPC、POSIX_MQUEUE、IPC_NS、PID_NS、DEVTMPFS、
USER_NS、TMPFS_XATTR/POSIX_ACL、NETFILTER_XT_MATCH_ADDRTYPE、IP_SET，全部由
`dash_gki.fragment` 补齐；UTS_NS、OVERLAY_FS、SECCOMP、VETH、CGROUP_FREEZER、MEMCG
stock 已有。

## 来源

- 基底（vendor）：<https://github.com/MiCode/Xiaomi_Kernel_OpenSource>（`dash-w-oss`）
- 基底（upstream）：<https://android.googlesource.com/kernel/common>（`android15-6.6-2026-01_r1`）
- DroidSpaces：<https://github.com/ravindu644/Droidspaces-OSS>
- SukiSU Ultra：<https://github.com/SukiSU-Ultra/SukiSU-Ultra>（`builtin` 分支）
- SUSFS：<https://gitlab.com/simonpunk/susfs4ksu>（`gki-android15-6.6`）
- KernelPatch：<https://github.com/bmax121/KernelPatch>
- kpimg：<https://github.com/ShirkNeko/SukiSU_patch>
- AnyKernel3 模板：<https://github.com/Numbersf/AnyKernel3>
- 基底合并过程：[docs/base-merge-6.6.118.md](docs/base-merge-6.6.118.md)
- 树内 delta 的来历：[docs/in-tree-deltas.md](docs/in-tree-deltas.md)
- 版本冻结：[docs/version-pins.md](docs/version-pins.md)
