#!/usr/bin/env python3
"""patch-kcrctab.py — 改写 Image 里 __kcrctab(_gpl) 的 CRC，用于对齐厂商模块的
modversions 期望值。

背景（dash OS4，2026-10-29 实测）：
  自编内核补的 13 个 MTK vendor hook 中，`android_vh_mmap_lock_init/_free` 两个
  hook 的 `__tracepoint_*` 符号 CRC 与 stock 内核不一致（其余 11 个、以及全部
  `__traceiter_*` 的 CRC 都逐位相同）。结果是 `os_cpu_qi.ko` 在加载时报
  `disagrees about version of symbol __tracepoint_android_vh_mmap_lock_init`
  → `-EINVAL` 拒载，连带 os_cpu_qs / task_turbo / mi_game / cpq / mi_reclaim
  整条 QoS 模块链都起不来。
  CRC 只在模块加载时被比较一次，改表不影响任何内核运行路径；两个 hook 的
  KCFI 原型哈希已由 verify-os4-kcfi.py 逐位验证，所以这里钉回 stock 的 CRC
  等价于「用 stock 的声明编出来的表」。

用法:
  patch-kcrctab.py <Image> <ELF> NAME=CRC [NAME=CRC ...] [--require]
  patch-kcrctab.py <Image> <ELF> --list [NAME ...]

  ELF 可以是 vmlinux，也可以是用 vmlinux-to-elf 从 Image 还原出来的 ELF
  （CI 的 export 门禁已经会准备这个文件）。

映射关系: vmlinux-to-elf 把 Image 原样放进 .kernel 段（ELF 文件偏移 sec_off
对应 Image 偏移 0），所以 Image 偏移 = vaddr - sec_addr。
"""
import argparse
import struct
import subprocess
import sys


def readelf_syms(elf):
    out = subprocess.run(["readelf", "-sW", elf], capture_output=True, text=True).stdout
    sym = {}
    for line in out.splitlines():
        p = line.split()
        if len(p) >= 8 and p[3] in ("OBJECT", "FUNC", "NOTYPE") and p[6] != "UND":
            try:
                v = int(p[1], 16)
            except ValueError:
                continue
            sym.setdefault(p[7], v)
    return sym


def kernel_section(elf):
    out = subprocess.run(["readelf", "-SW", elf], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if " .kernel " in line:
            p = line.split()
            for i, tok in enumerate(p):
                if tok == ".kernel":
                    return int(p[i + 2], 16), int(p[i + 3], 16)
    # 真实 vmlinux 没有合成的 .kernel 段：用第一个 SHF_ALLOC 段近似（只在
    # vmlinux-to-elf 产物上需要精确映射，所以这里报错退出更安全）
    sys.exit("ELF has no .kernel section - pass an ELF reconstructed from the Image")


class Img:
    def __init__(self, elf):
        self.data = open(elf, "rb").read()
        self.sym = readelf_syms(elf)
        self.sec_addr, self.sec_off = kernel_section(elf)

    def read(self, vaddr, n):
        off = self.sec_off + (vaddr - self.sec_addr)
        return self.data[off:off + n]

    def image_off(self, vaddr):
        return vaddr - self.sec_addr

    def walk(self):
        s = self.sym
        tables = [
            ("nongpl", s["__start___ksymtab"], s["__stop___ksymtab"], s["__start___kcrctab"]),
            ("gpl", s["__start___ksymtab_gpl"], s["__stop___ksymtab_gpl"], s["__start___kcrctab_gpl"]),
        ]
        for tname, start, stop, cstart in tables:
            n = (stop - start) // 12
            for i in range(n):
                a = start + 12 * i
                _v, n_off, _ns = struct.unpack("<iii", self.read(a, 12))
                name_addr = a + 4 + n_off
                if not (self.sec_addr <= name_addr < self.sec_addr + len(self.data)):
                    continue
                try:
                    name = self.read(name_addr, 96).split(b"\0")[0].decode()
                except UnicodeDecodeError:
                    continue
                cv = cstart + 4 * i
                yield tname, name, struct.unpack("<I", self.read(cv, 4))[0], cv


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("elf")
    ap.add_argument("pairs", nargs="*")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--require", action="store_true", help="missing symbol => error")
    a = ap.parse_args()

    img = Img(a.elf)

    if a.list or not a.pairs:
        want = set(a.pairs) if a.pairs else None
        for tname, name, crc, _cv in img.walk():
            if want is None or name in want:
                print("%s %-60s crc=0x%08x" % (tname, name, crc))
        return

    edits = {}
    for p in a.pairs:
        name, _, crc = p.partition("=")
        if not crc:
            sys.exit("bad pair (want NAME=0xCRC): " + p)
        edits[name] = int(crc, 16)

    found = {}
    for tname, name, crc, cv in img.walk():
        if name in edits:
            found[name] = (crc, cv)

    missing = sorted(set(edits) - set(found))
    if missing:
        msg = "symbols not found in ksymtab: " + ", ".join(missing)
        if a.require:
            sys.exit("::error::" + msg)
        print("warning::" + msg + " (skipped)")
        if not found:
            return

    data = bytearray(open(a.image, "rb").read())
    # ELF/Image 同源校验：Image 开头 64 字节必须与 .kernel 段一致
    head = img.data[img.sec_off:img.sec_off + 64]
    if bytes(data[:64]) != head:
        sys.exit("::error::Image and ELF do not match (different build?) - refusing to patch")
    changed = 0
    for name, (old, cv) in sorted(found.items()):
        new = edits[name]
        off = img.image_off(cv)
        cur = struct.unpack("<I", data[off:off + 4])[0]
        if cur == new:
            print("%-60s already 0x%08x" % (name, new))
            continue
        if cur != old:
            sys.exit("::error::%s: Image byte mismatch at 0x%x (image 0x%08x, elf 0x%08x)"
                     % (name, off, cur, old))
        data[off:off + 4] = struct.pack("<I", new)
        changed += 1
        print("%-60s 0x%08x -> 0x%08x (image off 0x%x)" % (name, old, new, off))

    open(a.image, "wb").write(data)

    # 复读校验：改完的字节必须就是目标值
    back = open(a.image, "rb").read()
    for name, (_old, cv) in found.items():
        off = img.image_off(cv)
        got = struct.unpack("<I", back[off:off + 4])[0]
        if got != edits[name]:
            sys.exit("::error::%s: read-back 0x%08x != target 0x%08x" % (name, got, edits[name]))
    print("patched %d entr%s in %s" % (changed, "y" if changed == 1 else "ies", a.image))


if __name__ == "__main__":
    main()
