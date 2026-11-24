# 版本冻结

外部组件的版本都钉死，改 pin 时同步改这里和 `.github/workflows/build.yml` 的 `env:`。

## 固定版本

| 组件 | 版本 / 提交 | 位置 |
|---|---|---|
| SukiSU Nova | `builtin` 分支 `4bec532dd447`（3.x 版本线，UAPI 6） | CI `KSU_PIN` |
| SUSFS | `susfs4ksu` `gki-android15-6.6` @ `f98f08223bbf`（v2.4.0） | CI `SUSFS_PIN` |
| KernelPatch | `bmax121/KernelPatch` @ `d4c88d667268` | CI `KP_PIN` |
| kpimg | `SukiSU-Nova/SukiSU_patch` @ `eec45788c9a1` | CI `KPIMG_COMMIT` / `KPIMG_SHA256` |
| AnyKernel3 | `Numbersf/AnyKernel3` | CI `AK3_PIN` |

## 怎么检出

CI 不调用 SukiSU 仓库里的 `setup.sh`，自己 clone + checkout：

```bash
git clone --filter=blob:none https://github.com/SukiSU-Nova/SukiSU-Nova.git ~/gki/KernelSU
git -C ~/gki/KernelSU checkout <KSU_PIN>
```

`setup.sh` 只额外做三件事——建 `drivers/kernelsu` 软链、往 `drivers/Makefile` 加
`obj-$(CONFIG_KSU) += kernelsu/`、往 `drivers/Kconfig` 加 `source "drivers/kernelsu/Kconfig"`，
CI 里照抄这三步并断言 `HEAD == KSU_PIN`。

不调用它的原因：`setup.sh` 的克隆源漂过三次（`ShirkNeko/` → `SukiSU-Ultra/` →
2026-11 起的第三方自建 Gitea `git.zako.shirkneko.top:20004/shirkneko/SukiSU`），
最后一次在 run 44980731191 直接把构建打红：那份 Gitea 历史里没有
`builtin@b16e899a`，`git checkout` 失败后落到 `|| echo "[-] Checkout default branch"`，
拿到没有 `KSU_SUSFS` 的默认分支，配对门禁报 10 个 `ksu_*()` 缺失。

## 版本线：Ultra 4.x → Nova 3.x

上游 2026-11-16 的 `c60f21b9`（"rename SukiSU-Ultra to SukiSU-Nova / Rebrand the
project and start a fresh 3.x version line"）不只是改名，版本号也重置了：

| | `VERSION_BASE` | `VERSION_TAG` |
|---|---|---|
| 旧 pin `b16e899a`（2026-10-30） | 40000 | 4.2.1 |
| 现 pin `4bec532`（2026-11-16） | 30000 | 3.0.0 |

`VERSION_BASE` 决定编进内核的 `KSU_VERSION`，管理器 APK 按它判断兼容性。所以内核和
APK 必须同一条版本线：**3.x 内核配 SukiSU Nova 的 APK，不能配 4.x 的 Ultra APK**。

`builtin` 分支不是 `main` 的子分支，但它的 `Makefile` 也已经在 3.x 号段上，改名后从
`builtin` 取到的提交一律是 3.x。

## 升级到 Nova 时 SUSFS 也得跟着动

KSU 从 `b16e899a` 换到 `4bec532` 后，`kernel/selinux/sepolicy.c` 开始调用
`susfs_add_sus_type()` 和 `susfs_add_sus_avd_allowed_by_type()`，而旧的
`susfs4ksu@9311456` 两个都没有——本地跑配对门禁直接拒绝：

```
::error::  - susfs_add_sus_type(): called by the KSU tree, not provided by the pinned susfs4ksu kernel side
::error::  - susfs_add_sus_avd_allowed_by_type(): 同上
```

两个函数随 `8934afa`（"Refactor selinux_hide"）进入 susfs4ksu。现 pin `f98f082`
（v2.4.0，与 KSU pin 同一窗口）带着它们，`50_` patch 也多了
`security/selinux/ss/services.c`、`status.c` 两处 hook，实测能干净 apply 到 6.6.143 树。

## 为什么不用 release tag

SukiSU 的 release 走 main 线，**不带 built-in SUSFS**：

```
v4.3.0             kernel/Kconfig 里 config KSU_SUSFS 的数量 = 0
v4.2.1-r2          同上 = 0
builtin@b16e899a   同上 = 10   (4.x 线)
builtin@4bec532    同上 = 11   (3.x 线，多一个 PRIORITY_UID_FILTER)
```

而 `builtin` 分支没有任何 tag / release。所以：

- 用 release tag：全部 `CONFIG_KSU_SUSFS*` 会被 kconfig 静默丢弃，构建「成功」但 SUSFS
  功能不存在；
- 用 `builtin` 的浮动 HEAD：会随上游漂移，曾出现 `kernel_umount_feature_set()` 被删但仍在
  `.set_handler` 里引用、构建 12 分钟后才报错的情况。

所以钉 `builtin` 的一个具体 commit，取 release 发布日当天的 builtin tip，并把配套的
susfs4ksu commit 一起钉死。

## 为什么这一对能配

两个方向都可能漂（`.github/scripts/check-susfs-pair.py` 的注释里记了例子）：

1. SUSFS → KSU：新 patch 调用 KSU 里没有的 `ksu_*()`，例如 `ksu_install_su_fd()`；
2. KSU → SUSFS：新 KSU 调用 SUSFS 里没有的 `susfs_*()` 或新 supercall，例如 `b5917072`
   要 `susfs_parse_priority_app_strings()`，配 `8224c73` 会链接失败。

当前这一对的状态：

- `builtin@4bec532` 调用的 34 个 `susfs_*()` 全部由 `f98f082` 的内核侧提供；
- patch 新增行里的 17 个 `ksu_*()` 全部存在于 KSU 树。

静态门禁在复制 SUSFS 文件之后立刻跑，构建开始前就能失败。

## CI 断言

`Setup SukiSU Nova` 步骤在配对门禁之后检查：

- `KernelSU` 的 `HEAD` 等于 `KSU_PIN`；
- `/tmp/susfs4ksu` 的 `HEAD` 等于 `SUSFS_PIN`；
- `drivers/kernelsu/Kconfig` 里 `^config KSU_SUSFS` 恰好 11 项（防止有人把 pin 换成
  release 或 main）；
- 打印 KSU / SUSFS 的 commit、日期和 `SUSFS_VERSION`。

## 升级流程

1. 看 `builtin` 与 `susfs4ksu gki-android15-6.6` 的最新提交，取同一天的组合；
2. 本地先跑静态门禁（可以脱离内核树）：

   ```bash
   git clone --depth 1 -b builtin https://github.com/SukiSU-Nova/SukiSU-Nova.git /tmp/ksu
   git clone --depth 25 -b gki-android15-6.6 https://gitlab.com/simonpunk/susfs4ksu.git /tmp/susfs
   mkdir -p /tmp/t/{drivers,fs,include/linux}
   cp -r /tmp/ksu/kernel /tmp/t/drivers/kernelsu
   cp /tmp/susfs/kernel_patches/fs/* /tmp/t/fs/
   cp /tmp/susfs/kernel_patches/include/linux/* /tmp/t/include/linux/
   python3 .github/scripts/check-susfs-pair.py --tree /tmp/t \
     --ksu /tmp/t/drivers/kernelsu \
     --susfs-patch /tmp/susfs/kernel_patches/50_add_susfs_in_gki-android15-6.6.patch
   ```

3. 改 workflow 的 `KSU_PIN` / `SUSFS_PIN` 和本文表格，推上去看 CI；
4. CI 绿之后必须上机验证开机，这是唯一能证明「不是又一个无法开机的组合」的手段：
   从 CI 下载 `Image`，用 magiskboot 配上原 boot 的 ramdisk 重打，刷到 `boot_b`；
   开机后确认 `unknown symbol` 计数为 0、`/data/adb/ksu` 存在、`su` 可用；
5. 失败就回滚到上一组已知可开机的 pin（`b16e899a` + `9311456`，4.x 线；
   再往前是 `b5917072` + `0606e19`）再排查。

换版本线（4.x ↔ 3.x）时还要同步换管理器 APK，见上文「版本线」。

## 已知可开机的组合

| KSU | SUSFS | 验证 |
|---|---|---|
| `b59170724cdc`（2026-10-27） | `0606e19afae9`（2026-10-27） | run 41182178821 构建，刷 boot_b 开机，583 模块 / unknown=0 / KSU 4.3.0 root |
| `b16e899a555e`（2026-10-30） | `93114563fd6b`（2026-10-29） | run 41193522848 双变体绿，刷 boot_b 开机，583 模块 / unknown=0 / SUSFS 生效（4.x 线） |

`4bec532` + `f98f082`（Nova 3.x）只做到「本地静态门禁通过」，还没上过机，上机之前
不要把它当成已知可开机组合。

`b5917072` 之后上游把 `allowlist.c` 的 `fall through` 注释改成了带版本判断的写法，我们的
sed 重写对新 pin 无害，等确认稳定后可以删掉。

## 回滚

上一组（`b5917072` + `0606e19`）构建的 `boot_b` 镜像还在本地，直接刷回即可：

```bash
fastboot flash boot_b <上一组的 boot 镜像>
```
