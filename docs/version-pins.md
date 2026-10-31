# 版本冻结（SukiSU / SUSFS / KernelPatch）

> 这份文档是「为什么钉这个 commit」的唯一出处。改 pin 必须同时改这里、CI 断言和
> `docs/version-pins.md` 里记录的验证结果。

## 1. 现状（2026-10-31）

| 组件 | 钉住的对象 | 日期 | 说明 |
|---|---|---|---|
| SukiSU Ultra（内核侧） | `builtin` 分支 `b16e899a555e` | 2026-10-29 | 构建期由 `kernel/setup.sh` 拉到 `~/gki/KernelSU` |
| susfs4ksu（内核侧） | 分支 `gki-android15-6.6` `93114563fd6b` | 2026-10-29 | 复制 `kernel_patches/{fs,include/linux}/*` 并 apply `50_add_susfs_in_gki-android15-6.6.patch` |
| KernelPatch（KPM 预补丁） | `SukiSU_patch` 的 `d4c88d66` + kpimg `eec45788` | — | 见 workflow 里的 `KPIMG_COMMIT` |
| 验证 | run `41182178821` 的 ksu/bypass 双变体 + 真机 boot | — | 每次升 pin 都要重跑 |

## 2. 为什么不是「最新 release tag」

SukiSU 的 release（main 线）**不带 built-in SUSFS**：

```
v4.3.0            kernel/Kconfig 里 config KSU_SUSFS 的数量 = 0
v4.2.1-r2         同上 = 0
builtin@b16e899a  同上 = 10
```

而 `builtin` 分支没有任何 tag / release。所以：

- 用 release tag → `CONFIG_KSU_SUSFS*` 10 项全部被 kconfig 静默丢弃（marble 时期的教训），
  构建“成功”但 SUSFS 功能不存在；
- 用 `builtin` 分支的浮动 HEAD → 会随上游漂移，曾出现 `kernel_umount_feature_set()`
  被删但仍在 `.set_handler` 里引用（run 34441463481，构建 12 分钟后才报错）。

因此冻结策略是：**钉 `builtin` 的一个具体 commit，取「release 发布日当天的 builtin tip」**，
并把配套的 susfs4ksu commit 一起钉死。

## 3. 为什么这一对能配

两个方向都可能漂（见 `.github/scripts/check-susfs-pair.py` 的注释）：

1. SUSFS → KSU：新 patch 调用 KSU 没有的 `ksu_*()`（例：`ksu_install_su_fd()`，run 34444400054）；
2. KSU → SUSFS：新 KSU 调用 SUSFS 没有的 `susfs_*()` / 新 supercall（例：`b5917072` 要
   `susfs_parse_priority_app_strings()`，用 8224c73 会链接失败，run 40811464365）。

现在这一对的状态：

- `builtin@b16e899a` 调用的 32 个 `susfs_*()` 全部由 `9311456` 的内核侧提供；
- patch 新增行里的 17 个 `ksu_*()` 全部存在于 KSU 树；
- 静态门禁在复制 SUSFS 文件后 1 秒内跑完，构建前就能失败。

`9311456`（“KernelSU: Fix compiler error”）只改了 `kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch`
——那是给 main 线 KSU 用的补丁，**builtin 流程不消费它**；我们复制的内核侧文件与 50_ patch
与 `0606e19`（上一版 pin）逐字节相同。

## 4. CI 里的冻结断言

`Setup SukiSU Ultra ...` 步骤在配对门禁之后立刻检查：

- `KernelSU` 的 `HEAD` == `github.sha` 对应的 `KSU_PIN`；
- `/tmp/susfs4ksu` 的 `HEAD` == `SUSFS_PIN`；
- `drivers/kernelsu/Kconfig` 里 `^config KSU_SUSFS` 恰好 10 项（防止有人把 pin 换成 release/main）；
- 打印 KSU/SUSFS 的 commit + 日期 + `SUSFS_VERSION`，让日志本身就是一份版本清单。

## 5. 升级流程（下次要动 pin 时）

1. 看 `builtin` 与 `susfs4ksu gki-android15-6.6` 的最新提交，取同一天的组合；
2. 本地先跑静态门禁（可脱离内核树）：

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

3. 改 workflow 的 `KSU_PIN` / `SUSFS_PIN` + 本节表格，推上去看 CI；
4. CI 绿后**必须上机验证开机**（这是唯一能证明“不是又一个无法开机的组合”的手段）：
   `prep-kernel.sh <run-id>` → `flash-ksu-b.sh <img>` → `postboot-check.sh`，并确认
   `unknown symbol = 0`、`/data/adb/ksu` 存在、`su` 可用；
5. 若失败：回滚到上一组已知可开机的 pin（`b5917072` + `0606e19`，见 §6）再排查。

## 6. 已知可开机的历史组合

| KSU | SUSFS | 结果 |
|---|---|---|
| `b59170724cdc` (2026-10-27) | `0606e19afae9` (2026-10-27) | ✅ 2026-10-31 实测：run 41182178821 构建并刷入 boot_b，跑通（583 模块 / unknown=0 / KSU 4.3.0 root） |
| `b16e899a555e` (2026-10-29) | `93114563fd6b` (2026-10-29) | 本次升级候选，验证结果见下节 |

> 注意：`b5917072` 之后上游把 `allowlist.c` 的 `fall through` 注释改成了
> `#if LINUX_VERSION_CODE > KERNEL_VERSION(5,6,0) fallthrough; #else /* fall through */`，
> 我们的 sed 重写仍在（对新 pin 无害），等确认新 pin 稳定后可以删掉这段 workaround。

## 7. 本次升级的验证记录

（CI run / 上机结果填在这里）