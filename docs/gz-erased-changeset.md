# dash (Redmi Turbo 5 Max / MT6991Z) — gz-erased 双态系统修改清单

状态截至 2026-10-03，全部条目均有实测锚点；分区指纹为当次 dd 校验。

## 0. 设备当前分区状态

| 分区 | 内容 | md5（dd 校验） |
|---|---|---|
| boot_a | CI 构建内核（nvhe + trusty_rescue 内置），AK3 直刷 | `09011fc0…`（≠ 任何字节手术 boot） |
| vendor_boot_a | v15（见 §2） | `449da7a8221bc220532d70b8c4b9620c` |
| gz_a | 擦除（GenieZone/Trusty 固件置零，让内核拿 EL2） | 全零区 |

运行事实：EL2 + nVHE KVM（/dev/kvm 在）、AVB green、WiFi/BT/充电/指纹正常、
三摄拍照录像正常、开机 18.9s trusty_rescue 自动完成相机链救援。

## 1. 内核侧（本仓库，CI 注入）

历史既有（DroidSpaces/SukiSU 线，非本文重点）：SYSVIPC/kABI 补丁、pid_max clamp、
KSU+KPM+SUSFS（ksu variant）、MODULE_SIG_PROTECT off、LTO_NONE+CFI 对齐 stock。

本次新增（commit 6f1fd6e + fix）：

### 1.1 CONFIG_CMDLINE: kvm-arm.mode protected → nvhe
- 位置：`arch/arm64/configs/gki_defconfig` 的 `CONFIG_CMDLINE="…"`，由
  `.github/scripts/inject-rescue.sh` sed 翻转 + ikconfig 双向断言
  （必须见 nvhe、必须无 protected）。
- 原理：`kvm-arm.mode=protected` 是编译进内核的内置 cmdline（DTB/ramdisk 里都没有），
  原厂时代只能对 boot 做字节手术；自研内核直接在源码改，零 AVB 风险。
  `CMDLINE_EXTEND` 下该串就是实际生效值（实测 /proc/cmdline）。
- gz 正常态安全性：gz 在位 → LK 把内核起在 EL1 → KVM init 整体跳过
  （`KVM is not available. Ignoring kvm-arm.mode`），nvhe 字符串无害。

### 1.2 drivers/trusty_rescue（CONFIG_TRUSTY_RESCUE=y，bool 内置）
- 源文件：本仓库 `rescue/`，注入钩子见 inject-rescue.sh。
- 要解决的问题：gz 擦除 → trusty SMC 版本握手失败 → gz_trusty_mod 的
  trusty_probe 返回 -22 → 其尾部 of_platform_populate("/trusty") 未执行 →
  /trusty/trusty-virtio 设备不存在 → gce-mbox-sec/-m-sec（secure cmdq mailbox）
  supplier 断链 deferred → camera-imgsys-cmdq 不完整 → 34000000.imgsys-fw 永不
  绑定 → IMGSCP 不上电 → camisp media 拓扑 0 实体 → camerahalserver 崩溃循环。
- 行为：3s 后起 delayed work，1s 粒度轮询三段指纹——
  ① bus 上存在名为 `trusty-virtio` 的 driver ② 其 DT 对应 platform device 缺失
  ③ `/trusty` 父设备未绑定驱动；三者连续成立 ≥15s 才动作（grace），总窗口 90s：
  a. `bus_for_each_drv` 迭代锁内 `try_module_get(owner)` 永久 pin gz_virtio_mod
     （防 rmmod 双注销 UAF；pin 失败则放弃动作）；
  b. `driver_unregister` 摘除 trusty_virtio_driver——它的 probe 会对 NULL
     trustye 解引用直接 ipanic（v1 实测炸过，pstore 有档案）；
  c. `of_platform_device_create` 造 trusty-virtio marker 设备（secure-cmdq 的
     probe 只做 of_find_compatible_node + device_link_add，设备"存在"即可解锁，
     无驱动可 bind → 无 probe → 无雷）；
  d. `driver_deferred_probe_trigger()` 唤醒整条 deferred 链。
- 自守卫：gz 完好时 trusty_probe 毫秒级绑父设备+造子设备，指纹 ②③ 永远不成立
  → 纯 no-op。任何异常/外平台/DT 缺节点 → 不动作。
- 已知且预期：开火前 init 拉起的首个 camerahalserver（~6.7s）会崩一次，
  重启后的 HAL 赶上救援完成的窗口，之后永稳。
- 工程红线（CI run #1 教训）：禁止 `driver_find()`+`put_device(&drv->p)`——
  `device_driver.p` 是私有 `struct driver_private *`，其配对 `put_driver()` 不导出。
  只用公开 API。
- 同名雷排除：ise 栈驱动在 bus 上注册名是 `ise-trusty-virtio`（sysfs 实证），
  精确 strcmp 不会误摘。

## 2. vendor_boot 侧（当前 v15 = 原厂 vendor_boot 之上的净修改）

版本谱系：v12（log_store 补丁 + devapc skip + cmdline）→ v14（+Mali 闸门）→
v15（devapc 撤销回原厂，判别实验定案 devapc 无罪）。v15 净差异 = 下表三项，
其余逐字节等长、AVB struct/footer 零变动：

| # | 位置 | 改动 | 作用 | 新内核下是否仍需 |
|---|---|---|---|---|
| 1 | vendor_ramdisk 内 `log_store.ko` | `.text(0x1000)+0xbe4` 一条 `str xzr,[x19]` → NOP（等长） | 修 gz 擦除态下该模块的 NULL 写崩溃（早期 ramoops `set_boot_phase+0x3c` panic） | 是。vendor 模块，内核管不到 |
| 2 | DTB strings 块 | Mali 节点属性名 `protected-memory-allocator`→`protected-memory-allocatoX`（等长改名） | 关 kbase protected-memory 路径：gz 擦除时 `mtee_assign_buffer_v2` SMC 返 -22 → mali prot alloc NULL deref ipanic | **是，且长期是**。DT 级闸门，graphicsengine 加载 CSF 固件即触发，与救援无关 |
| 3 | vendor_boot header `cmdline` 字段 | 追加 `nogzpatch=1 dapcdt=1` | v12 遗留开关，消费者未逐一定位（疑 vendor 侧） | **存疑保留**——相机链已由内核救援解决，理论上可能可删；未做删除回归前不动 |

镜像文件：`~/hermes_work/vendor_boot_a_nogz_patched_v15_devapc_on.img`
（md5 `449da7a8…`，sha256 `6093b684…`，元数据 `v15_meta.json`）。
构建脚本（等长 DTB/ko 手术范式，防 magiskboot v31 repack 破坏 AVB image_size 的
历史坑，一律手写二进制编辑）：`build_v14_mali.py`、`build_v15_devapc_on.py`、
`patch_vendorboot.py`、`build_nvhe_safe.py`（boot 侧字节手术——已被 §1.1 取代，退役）。

## 3. 分层职责速查

```
EL2/内核模式 (nvhe)        → 内核 CONFIG_CMDLINE          （本仓库 CI）
trustey-virtio 链救援      → 内核 drivers/trusty_rescue   （本仓库 CI）
Mali protected 闸门        → vendor_boot DTB              （v15）
log_store 崩溃             → vendor_boot vendor_ramdisk   （v15）
gz↔EL2 互换               → 只动 gz_a 分区              （fastboot flash/erase，由人执行）
```

日常↔VM 一体后不再需要双模式镜像组；恢复"全原厂含 gz"路径 = flash 回原厂
gz_a + 原厂 vendor_boot + 原厂 boot（v15 的三处改动理论上也兼容 gz 在位态，
Mali 闸门最多使受保护视频通路退化，未实测，标注为待验）。

## 4. 未验项（诚实清单）

- gz 恢复 + 新内核 + v15 组合的开机回归（预期：rescue 静默、KVM 报 not
  available、其余如原厂）——未实测。
- DRM 受保护流媒体在 gz 擦除态（widevine L1 类）：预期失败（真 SMC 依赖），未测。
- v15 cmdline `nogzpatch/dapcdt` 能否删除：消费者未定位，未做单变量实验。
- HAL 开火前那一次崩溃是否可消除（如 settle 提前）：当前判定为无必要。
