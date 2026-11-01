# 版本冻结

外部组件的版本都钉死，改 pin 时同步改这里和 `.github/workflows/build.yml` 的 `env:`。

## 固定版本

| 组件 | 版本 / 提交 | 位置 |
|---|---|---|
| SukiSU Ultra | `builtin` 分支 `b16e899a555e`（UAPI 6） | CI `KSU_PIN` |
| SUSFS | `susfs4ksu` `gki-android15-6.6` @ `93114563fd6b` | CI `SUSFS_PIN` |
| KernelPatch | `bmax121/KernelPatch` @ `d4c88d667268` | CI `KP_PIN` |
| kpimg | `ShirkNeko/SukiSU_patch` @ `eec45788c9a1` | CI `KPIMG_PIN` / `KPIMG_SHA256` |
| AnyKernel3 | `Numbersf/AnyKernel3` | CI `AK3_PIN` |

## 为什么不用 release tag

SukiSU 的 release 走 main 线，**不带 built-in SUSFS**：

```
v4.3.0             kernel/Kconfig 里 config KSU_SUSFS 的数量 = 0
v4.2.1-r2          同上 = 0
builtin@b16e899a   同上 = 10
```

而 `builtin` 分支没有任何 tag / release。所以：

- 用 release tag：10 个 `CONFIG_KSU_SUSFS*` 会被 kconfig 静默丢弃，构建「成功」但 SUSFS
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

- `builtin@b16e899a` 调用的 32 个 `susfs_*()` 全部由 `9311456` 的内核侧提供；
- patch 新增行里的 17 个 `ksu_*()` 全部存在于 KSU 树。

静态门禁在复制 SUSFS 文件之后立刻跑，构建开始前就能失败。

`9311456`（"KernelSU: Fix compiler error"）只改了
`kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch`，那是给 main 线 KSU 用的补丁，
builtin 流程不消费它；我们复制的内核侧文件与 50_ patch 与 `0606e19` 逐字节相同。

## CI 断言

`Setup SukiSU Ultra` 步骤在配对门禁之后检查：

- `KernelSU` 的 `HEAD` 等于 `KSU_PIN`；
- `/tmp/susfs4ksu` 的 `HEAD` 等于 `SUSFS_PIN`；
- `drivers/kernelsu/Kconfig` 里 `^config KSU_SUSFS` 恰好 10 项（防止有人把 pin 换成
  release 或 main）；
- 打印 KSU / SUSFS 的 commit、日期和 `SUSFS_VERSION`。

## 升级流程

1. 看 `builtin` 与 `susfs4ksu gki-android15-6.6` 的最新提交，取同一天的组合；
2. 本地先跑静态门禁（可以脱离内核树）：

   ```bash
   git clone --depth 1 -b builtin https://github.com/SukiSU-Ultra/SukiSU-Ultra.git /tmp/ksu
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
   `prep-kernel.sh <run-id>` → `flash-ksu-b.sh <img>` → `postboot-check.sh`，确认
   `unknown symbol = 0`、`/data/adb/ksu` 存在、`su` 可用；
5. 失败就回滚到上一组已知可开机的 pin（`b5917072` + `0606e19`）再排查。

## 已知可开机的组合

| KSU | SUSFS | 验证 |
|---|---|---|
| `b59170724cdc`（2026-10-27） | `0606e19afae9`（2026-10-27） | run 41182178821 构建，刷 boot_b 开机，583 模块 / unknown=0 / KSU 4.3.0 root |
| `b16e899a555e`（2026-10-30） | `93114563fd6b`（2026-10-29） | run 41193522848 双变体绿，刷 boot_b 开机，583 模块 / unknown=0 / SUSFS 生效 |

`b5917072` 之后上游把 `allowlist.c` 的 `fall through` 注释改成了带版本判断的写法，我们的
sed 重写对新 pin 无害，等确认稳定后可以删掉。

## 回滚

上一组（`b5917072` + `0606e19`）构建的 `boot_b` 镜像还在本地，直接刷回即可：

```bash
fastboot flash boot_b <上一组的 boot 镜像>
```
