#!/usr/bin/env python3
"""Verify the dash-OS4 vendor-hook stubs against the KCFI type hashes of the
stock kernel / stock vendor modules.

Background: with CONFIG_CFI_CLANG=y, `__traceiter_android_vh_*` loads the type
hash stored at -4(%probe) and compares it against an immediate that encodes the
hook's declared prototype; on mismatch it executes `brk #0x8228` -> instant
panic the first time the hook fires. The stock dash kernel and the stock modules
agree on these values:

  remove_mapping / remove_mapping_failed   0xad16e271
  filemap_get_folio_end                   0xaf94231e
  put_super                               0xcf650130
  fuse_request_end_ext / fetch            0x6d1df6d6
  mmap_lock_init / free                   0xb294fbeb
  percpu_rwsem_init                       0xdabec163
  rcu_boost_start / end                   0x922a38d6
  sync_rcu_wait_start / end               0x389e96a6

This script reads the *built* vmlinux, emulates the movz/movk sequence at the top
of each __traceiter_* and asserts the immediate equals the expected hash. Exits
non-zero on mismatch, so a bad prototype can never reach the flashable Image.

Usage: verify-os4-kcfi.py <vmlinux> [<built-config>]
"""

import struct
import sys

EXPECTED = {
    "android_vh_remove_mapping": 0xAD16E271,
    "android_vh_remove_mapping_failed": 0xAD16E271,
    "android_vh_filemap_get_folio_end": 0xAF94231E,
    "android_vh_put_super": 0xCF650130,
    "android_vh_fuse_request_end_ext": 0x6D1DF6D6,
    "android_vh_fuse_request_fetch": 0x6D1DF6D6,
    "android_vh_mmap_lock_init": 0xB294FBEB,
    "android_vh_mmap_lock_free": 0xB294FBEB,
    "android_vh_percpu_rwsem_init": 0xDABEC163,
    "android_vh_rcu_boost_start": 0x922A38D6,
    "android_vh_rcu_boost_end": 0x922A38D6,
    "android_vh_sync_rcu_wait_start": 0x389E96A6,
    "android_vh_sync_rcu_wait_end": 0x389E96A6,
}

SCAN_BYTES = 0x200


class Elf:
    def __init__(self, path):
        with open(path, "rb") as f:
            self.data = f.read()
        d = self.data
        if d[:4] != b"\x7fELF" or d[4] != 2:
            raise SystemExit("%s: not an ELF64 file" % path)
        self.shoff = struct.unpack_from("<Q", d, 0x28)[0]
        self.shentsize = struct.unpack_from("<H", d, 0x3A)[0]
        self.shnum = struct.unpack_from("<H", d, 0x3C)[0]
        self.shstrndx = struct.unpack_from("<H", d, 0x3E)[0]
        self.sections = []
        for i in range(self.shnum):
            off = self.shoff + i * self.shentsize
            name, sh_type = struct.unpack_from("<II", d, off)
            flags, addr, sh_off, size = struct.unpack_from("<QQQQ", d, off + 8)
            link, = struct.unpack_from("<I", d, off + 40)
            self.sections.append({
                "index": i, "name_off": name, "type": sh_type, "flags": flags,
                "addr": addr, "offset": sh_off, "size": size, "link": link,
            })
        self.sections[0]["name"] = ""
        names = self.sections[self.shstrndx]
        strtab = d[names["offset"]:names["offset"] + names["size"]]
        for s in self.sections:
            end = strtab.find(b"\0", s["name_off"])
            s["name"] = strtab[s["name_off"]:end].decode("ascii", "replace")

    def sec_of_addr(self, addr):
        for s in self.sections:
            if s["type"] != 8 and s["addr"] and s["addr"] <= addr < s["addr"] + s["size"]:
                return s
        return None

    def read_at_vaddr(self, addr, size):
        s = self.sec_of_addr(addr)
        if s is None:
            raise SystemExit("no section covers vaddr 0x%x" % addr)
        off = s["offset"] + (addr - s["addr"])
        return self.data[off:off + size]

    def symbols(self):
        out = {}
        for s in self.sections:
            if s["type"] != 2:  # SHT_SYMTAB
                continue
            strs = self.sections[s["link"]]
            strtab = self.data[strs["offset"]:strs["offset"] + strs["size"]]
            n = s["size"] // 24
            for i in range(n):
                off = s["offset"] + i * 24
                st_name, st_info, st_other, st_shndx, st_value, st_size = \
                    struct.unpack_from("<IBBHQQ", self.data, off)
                if not st_name or not st_value:
                    continue
                end = strtab.find(b"\0", st_name)
                name = strtab[st_name:end].decode("ascii", "replace")
                out.setdefault(name, st_value)
        return out


def decode_immediate(code):
    """Emulate movz/movk/movn over `code` and return the set of complete 32-bit
    values written to any register."""
    state = {}
    done = set()
    for i in range(0, len(code) - 3, 4):
        w = struct.unpack_from("<I", code, i)[0]
        if w == 0xD503233F:      # paciasp
            continue
        if w == 0xD65F03C0:      # ret
            break
        reg = w & 0x1F
        hw = (w >> 21) & 3
        imm = (w >> 5) & 0xFFFF
        if hw > 1:               # 64-bit movz/movk: skip (our constants are 32-bit)
            continue
        val, mask = state.get(reg, (0, 0))
        if (w & 0x7F800000) == 0x52800000:        # movz wN, #imm, lsl #(16*hw)
            val, mask = imm << (16 * hw), 0xFFFF << (16 * hw)
        elif (w & 0x7F800000) == 0x72800000:      # movk wN, #imm, lsl #(16*hw)
            val = (val & ~(0xFFFF << (16 * hw))) | (imm << (16 * hw))
            mask |= 0xFFFF << (16 * hw)
        elif (w & 0x7F800000) == 0x12800000:      # movn wN, #imm, lsl #(16*hw)
            val = ~(imm << (16 * hw)) & 0xFFFFFFFF
            mask = 0xFFFFFFFF
        elif (w & 0xFF800000) == 0x32000000:      # orr wN, wzr, #imm (bitmask)
            continue
        else:
            continue
        state[reg] = (val, mask)
        if mask & 0xFFFFFFFF == 0xFFFFFFFF:
            done.add(val & 0xFFFFFFFF)
    return done


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: %s <vmlinux> [built-config]" % sys.argv[0])
    vmlinux = sys.argv[1]
    config = sys.argv[2] if len(sys.argv) > 2 else None

    if config:
        try:
            cfg = open(config).read()
        except OSError:
            cfg = ""
        if "CONFIG_CFI_CLANG=y" not in cfg:
            print("verify-os4-kcfi: CONFIG_CFI_CLANG is not enabled -> hashes are "
                  "not embedded, skipping (module probes still load)")
            return 0

    elf = Elf(vmlinux)
    syms = elf.symbols()
    failures = []
    for hook, want in EXPECTED.items():
        name = "__traceiter_" + hook
        addr = syms.get(name)
        if addr is None:
            failures.append("%s: symbol missing (stub injection did not take)" % name)
            continue
        code = elf.read_at_vaddr(addr, SCAN_BYTES)
        got = decode_immediate(code)
        if want in got:
            print("  ok  %-46s 0x%08x" % (name, want))
            continue
        failures.append("%s: KCFI hash mismatch — expected 0x%08x, function encodes %s"
                        % (name, want, ", ".join("0x%08x" % v for v in sorted(got)) or "nothing"))

    if failures:
        for f in failures:
            print("::error::verify-os4-kcfi: " + f)
        return 1
    print("verify-os4-kcfi: all %d hook prototypes match the stock KCFI hashes"
          % len(EXPECTED))
    return 0


if __name__ == "__main__":
    sys.exit(main())