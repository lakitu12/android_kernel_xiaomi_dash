# v15 vendor_boot 具体修改的字节级说明

对象：`~/hermes_work/vendor_boot_a_nogz_patched_v15_devapc_on.img`
md5 `449da7a8221bc220532d70b8c4b9620c` / sha256 `6093b684…c8d4`
基线：原厂 `~/下载/vendor_boot_a.img`

## 0. 先说验证方法与两个易误导的现象

对原厂与 v15 做过三重取证：全文件逐字节 diff、两版 vendor_ramdisk 解包后
cpio **逐文件 md5 对比**、header 字段结构解析。结论与现象：

- 全文件 diff 有 8942 字节/90 段——**绝大部分不是修改**。构建链把 platform
  vendor_ramdisk 整段解压→（微改 cpio）→按 8 MiB 定长重新 LZ4-legacy 分块压缩，
  压缩器匹配选择与原厂不同，导致压缩流字节大面积变化，但 `RAMDISK_SZ` 与原厂
  **逐字节相等**（两侧均为 `0x3adc52f`）——是"同长度不同编码"，不是位移也不是改大。
- cpio 逐文件比对的结果才是真相：**整个 ramdisk 里只有 1 个文件被改**
  （`lib/modules/log_store.ko`，原厂 md5 `86a6b7a3…` → v15 内 `b6d90b1c…`），
  其余全部与原厂逐字节一致。
- 逻辑修改共 4 项（1 个 header 字段 + 1 个 .ko 两条指令 + 1 处 DTB 改名 +
  1 处 DTB 改名已回滚）；AVB 全程零触碰：ramdisk/dtb 尺寸不变，
  vbmeta struct/footer 不动，实测 `verifiedbootstate=green`。

## 1. header.cmdline 字段

- 偏移：header 页 `0x30` 起 256B 定长字符串区（vendor_boot v4 格式）。
  stock：`bootopt=64S3,32N2,64N2`；v15：`bootopt=64S3,32N2,64N2 nogzpatch=1 dapcdt=1`
  （magiskboot 复核一致）。
- 谱系：`nogzpatch=1` 自 v8 起就是"容器标记"（当时配套补丁就叫 nogz 补丁，
  供我们自己的 repack 脚本/校验认版本用）；`dapcdt=1` 是 v12 用 DTB skip 方案
  替代旧 `nodapc=1` 参数时一并改的。vendor 侧消费者未逐一定位，也无删除回归
  ——**存疑保留项**（两种态实测带着都正常）。

## 2. vendor_ramdisk: `/lib/modules/log_store.ko`（唯一被改的文件）

改在 `pl_lk_log_show()`（符号 0xe74 起）之内，`.text` 段文件偏移两处、共 5 字节，
全部等长替换。BuildID 锚定：`271867de…2cdf006`（脚本有断言）。

### 2a. 功能补丁：`0x1000 + 0xb88`（ko 内偏移 0x1b88）
```
stock:  81 02 00 54   b.eq  <panic分支>      ; SRAM 区头 magic 校验失败
v15   : 00 00 00 91   add x0, x0, #0         ; 即 nop
```
作用：gz 擦除态下 LK 写入 log_store SRAM 区的头/数据不存在或不合法，原厂此处
`b.eq` 跳入的处理路径会拿 NULL `sram_header` 继续往下走 → 早期实测
（boot 时代 ramoops）表现为 panic；NOP 后失败分支被吞掉，模块照常工作
（console-ramoops 导出功能不受影响，实测可拉）。
来源脚本：`repack_v8.py`（注释原文 "b.ne 0xbd8 (first SRAM-magic check ->
NULLs sram_header) -> add x0,x0,#0"，实际指令为 b.eq，v8→v9→v10→v11→v12 沿用），
产物文件 `v8_log_store_patched.ko`/`v9_log_store.ko`（md5 `b6d90b1c…`）。
注：`patch_vendorboot.py`（更早一轮实验，打在 `0x1be4` 的另一条
`str xzr,[x19]`→NOP，产物 md5 `1b83ddc7…`）**没有**进入 v12→v15 线上链，
本文档旧版误把它写成了现行补丁，已按 cpio 实物证据更正。

### 2b. 伪装性字符串微调：`0x207d`（同文件，rodata）
```
"  log_store: sram header address 0x%p."  → "  … header Address 0x%p."
```
（a→A，1 字节）。这是 repack_v9/v10 的压缩尺寸配平手法：重压缩流的输出字节数
受内容熵微扰影响，加一个无害大写让被改块压回与原厂**完全相同**的压缩长度，
从而不动 header、不挪后续任何偏移。属于工程手段，无运行时语义。

## 3. DTB：Mali 属性等长改名（v14 引入，现行存活）

- FDT strings 块一处，stock 内容（实测上下文）：
  `protected-memory-allocator\0` → `protected-memory-allocatoX\0`
  （27B 等长，仅末字节 `r`(0x72)→`X`(0x58)；v15 相对原厂 **FDT 差异仅此 1 字节**，
  FDT 内偏移 `0x79204`，两侧 FDT 总长同为 535899B）。
- 语义：`/soc/mali@48000000` 节点的 `protected-memory-allocator = <&gpu_protected_memory_allocator>`
  属性名变未知 → kbase `of_parse_phandle` 查不到 → 不走 protected memory 分配 →
  绕开 gz 擦除态 `mtee_assign_buffer_v2` SMC 返 -22 后 NULL deref 的 ipanic
  （v13 时代崩溃签名）。
- 唯一性保障：构建脚本（`build_v14_mali.py`）断言 strings 块全局命中恰 1 处、
  不与 `arm,protected-memory-allocator` 前缀混淆、struct 块节点名不动；
  产物 v14 与 v12 全文件差异恰 1 字节。**内核管不到，长期必须保留**。

## 4. DTB：devapc compatible（v12 改过 → v15 回滚，净效果为零）

- v12 曾把 strings 块 `mediatek,mt6991-devapc` → `mediatek,skip69-devapc`
  （等长改名跳过 AP devapc 驱动，当时用于相机问题隔离）。
- v15（`build_v15_devapc_on.py`）回滚：6 字节写回 `mt6991-`（文件偏移
  `0x3b15521–0x3b15526`，v15 与 v14 全文件差异恰此 6 字节）。
- 判别实验结论：devapc 恢复后相机症状不变（`driver registered` 日志实证）→
  无罪保留原厂值。当前镜像此项**与原厂一致**。

## 5. 版本谱系速查

```
stock(2e755ef8) ─v8: log_store NOP@0xb88(+Address 配平) + cmdline nogzpatch=1
              ─v9/v10/v11: 沿用，试验 kvmnvhe/nodapc 变体
              ─v12: DTB devapc→skip69，cmdline 定稿 "nogzpatch=1 dapcdt=1"
              ─v14: DTB Mali 改名 (build_v14_mali.py)
              ─v15: DTB devapc 还原 (build_v15_devapc_on.py)   ← 现行
```
自校验惯例：每版脚本"写后回读 + 与上一版逐字节 diff 断言差异恰 N 字节"。

## 6. 与内核侧修改的分工边界

| 需求 | 归属 | 载体 |
|---|---|---|
| 内核拿 EL2 / nVHE | 内核 | CONFIG_CMDLINE（CI） |
| 相机链 rescue | 内核 | drivers/trusty_rescue（CI） |
| Mali 不撞 mtee_assign | vendor_boot | §3 DTB 改名（kbase 是 vendor 模块） |
| LK log 区缺失不 panic | vendor_boot | §2a log_store NOP（vendor 模块） |
| gz↔EL2 切换 | 分区 | 只动 gz_a |

v15 的 §1/§2/§3 三处改动在 **gz 在位态同样存在且实测无害**（8 月 lakitu-1
基线的同款改动带 gz 正常开过机）；理论上 gz 恢复后 §2/§3 属"冗余但安全"。
未验项（DRM 受保护流退化、nogzpatch/dapcdt 可删性、三件套回滚矩阵）见
`gz-erased-changeset.md` §7 与本节记录，动手前勿当已证事实引用。
