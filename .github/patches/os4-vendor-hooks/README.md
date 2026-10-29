# dash OS4 vendor-hook patches

这一目录是「dash OS4 (HyperOS 4 / 6.6.118) 厂商模块所需、但 AOSP GKI 6.6 源里没有的
vendor hook」的全部改动，以标准 unified diff 维护，由
`.github/scripts/apply-patches.py` 统一打上。

## 为什么是补丁

* 一屏看完整个 delta，可 review、可 diff、可回滚；
* 应用器只做一件事：`git apply` / `patch`，失败就中止构建；
* 上游漂移时补丁会**干净地失败**（而不是脚本式插入「悄悄插错位置」）。

代价：上下文变了要重新生成补丁（见文末）。

## 内容

| 补丁 | 目标 | 说明 |
|---|---|---|
| 0001 | `include/trace/hooks/dash_os4_stub.h` | 13 个 `DECLARE_HOOK` + extern 原型 pin |
| 0002 | `drivers/android/vendor_hooks.c` | 挂进 `CREATE_TRACE_POINTS` + `EXPORT_TRACEPOINT_SYMBOL_GPL` |
| 0003 | `BUILD.bazel` + `android/abi_gki_aarch64_dash_os4` | KMI 白名单（27 符号，含 `LZ4_compress_default`） |
| 0004 | `mm/vmscan.c` | `remove_mapping` / `remove_mapping_failed` |
| 0005 | `mm/filemap.c` | `filemap_get_folio_end` |
| 0006 | `fs/super.c` | `put_super` |
| 0007 | `fs/fuse/dev.c` | `fuse_request_end_ext` / `fuse_request_fetch` |
| 0008 | `kernel/fork.c` | `mmap_lock_init` / `mmap_lock_free` |
| 0009 | `kernel/locking/percpu-rwsem.c` | `percpu_rwsem_init` |
| 0010 | `kernel/rcu/tree.c` + `tree_exp.h` + `tree_plugin.h` | `sync_rcu_wait_*` / `rcu_boost_*` |

## 两条硬约束

1. **TP_PROTO 不能改**：`CONFIG_CFI_CLANG=y` 下 `__traceiter_*` 会核对探针类型哈希，
   与原厂不一致会在 hook 触发时 `brk #0x8228`。现有原型是用
   `clang -fsanitize=kcfi` 复算、与 stock 内核立即数逐位对齐的（0001 的注释里列了
   全部哈希），`verify-os4-kcfi.py` 在构建后再验一次。
2. **KMI 白名单必须命中**：`trim_nonlisted_kmi=True` 会裁掉未列出的导出；白名单走
   独立文件 + `BUILD.bazel` 的 `aarch64_additional_kmi_symbol_lists`，不去改小米/MTK
   的大列表。

## 重新生成

基线是 `kernel/common` tag `android15-6.6-2026-01_r1`（6.6.118，`SUBLEVEL = 118`）。
原型/调用点的实测依据见 `~/下载/dash-os4/os4-hooks-callsite-map.md`。

```bash
# 1) 干净基线上应用全部补丁，做成 "after" 树
# 2) 改完补丁内容后，用同样方式生成新的 diff：
git -C <after-tree> diff --no-color -- <path> > 00NN-<name>.patch
```
