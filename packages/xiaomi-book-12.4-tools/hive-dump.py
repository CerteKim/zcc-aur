#!/usr/bin/env python3
"""Minimal read-only Windows registry hive reader.

Enough of the hive format (regf/hbin/nk/vk/lf/lh/li) to walk a hive and search
key paths and values, which is what we need to find the vendor's per-subsystem
PIL configuration (region addresses, PAS/processor ids, firmware names) that the
ACPI tables do not contain.

Usage:
    hive-dump.py <hive> [regex]

With a regex, only keys whose path matches (or whose data contains one of the
interesting addresses) are printed - the SYSTEM hive has ~200k keys.
"""
import re
import struct
import sys

MAX_DEPTH = 40


class Hive:
    def __init__(self, path):
        self.d = open(path, "rb").read()
        if self.d[:4] != b"regf":
            raise SystemExit("not a registry hive")
        # all cell offsets are relative to the start of the hive bins (0x1000)
        self.bins = 0x1000
        self.root = struct.unpack_from("<I", self.d, 0x24)[0]

    def _cell(self, off):
        off += self.bins
        size = struct.unpack_from("<i", self.d, off)[0]
        return off + 4, abs(size) - 4

    def _subkey_offsets(self, off):
        base, size = self._cell(off)
        sig = self.d[base:base + 2]
        out = []
        if sig in (b"lf", b"lh"):
            n = struct.unpack_from("<H", self.d, base + 2)[0]
            for i in range(n):
                out.append(struct.unpack_from("<I", self.d, base + 4 + i * 8)[0])
        elif sig == b"li":
            n = struct.unpack_from("<H", self.d, base + 2)[0]
            for i in range(n):
                out.append(struct.unpack_from("<I", self.d, base + 4 + i * 4)[0])
        return out

    def _values(self, off, count, list_off):
        vals = []
        if not count or not list_off:
            return vals
        base, size = self._cell(list_off)
        for i in range(min(count, size // 4)):
            voff = struct.unpack_from("<I", self.d, base + i * 4)[0]
            base2, _ = self._cell(voff)
            if self.d[base2:base2 + 2] != b"vk":
                continue
            nlen = struct.unpack_from("<H", self.d, base2 + 2)[0]
            dsize = struct.unpack_from("<I", self.d, base2 + 4)[0]
            doff = struct.unpack_from("<I", self.d, base2 + 8)[0]
            dtype = struct.unpack_from("<I", self.d, base2 + 12)[0]
            vflags = struct.unpack_from("<H", self.d, base2 + 0x10)[0]
            raw = self.d[base2 + 0x14:base2 + 0x14 + nlen]
            name = raw.decode("latin-1") if vflags & 0x1 else raw.decode("utf-16-le", "replace")
            if dsize & 0x80000000:
                data = struct.pack("<I", doff)[:dsize & 0x7FFFFFFF]
            else:
                db, _ = self._cell(doff)
                data = self.d[db:db + dsize]
            vals.append((name, dtype, data))
        return vals

    def key(self, off):
        base, _ = self._cell(off)
        if self.d[base:base + 2] != b"nk":
            return None
        subkey_count = struct.unpack_from("<I", self.d, base + 0x14)[0]
        subkey_off = struct.unpack_from("<I", self.d, base + 0x1C)[0]
        value_count = struct.unpack_from("<I", self.d, base + 0x24)[0]
        value_off = struct.unpack_from("<I", self.d, base + 0x28)[0]
        flags = struct.unpack_from("<H", self.d, base + 2)[0]
        name_len = struct.unpack_from("<H", self.d, base + 0x48)[0]
        raw = self.d[base + 0x4C:base + 0x4C + name_len]
        name = raw.decode("latin-1") if flags & 0x20 else raw.decode("utf-16-le", "replace")
        vals = self._values(off, value_count, value_off)
        subs = self._subkey_offsets(subkey_off) if subkey_count and subkey_off else []
        return name, vals, subs

    def walk(self, off=None, path="", depth=0):
        if depth > MAX_DEPTH:
            return
        off = self.root if off is None else off
        k = self.key(off)
        if not k:
            return
        name, vals, subs = k
        here = path + "\\" + name
        yield here, vals
        for s in subs:
            yield from self.walk(s, here, depth + 1)


def fmt(value):
    dtype, data = value[1], value[2]
    if dtype == 4 and len(data) == 4:
        return f"0x{struct.unpack('<I', data)[0]:08x}"
    if dtype in (3, 2):
        return data.rstrip(b"\0").decode("latin-1", "replace")
    return data[:32].hex()


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    pat = re.compile(sys.argv[2], re.I) if len(sys.argv) > 2 else None
    interesting = (b"venus", b"vss", b"vidc", b"video", b"pil", b"subsys")
    h = Hive(sys.argv[1])
    n = 0
    for path, vals in h.walk():
        blob = path.encode("latin-1", "replace").lower() + b" " + b" ".join(v[2] for v in vals)
        if pat is None:
            show = True
        else:
            show = bool(pat.search(path))
            if not show:
                show = any(i in blob for i in interesting)
        if not show:
            continue
        n += 1
        print(f"\n=== {path} ===")
        for v in vals:
            print(f"    {v[0]!r:40} type={v[1]} {fmt(v)}")
        if n > 400:
            print("\n... output capped")
            break
    print(f"\n{n} keys shown")


if __name__ == "__main__":
    main()
