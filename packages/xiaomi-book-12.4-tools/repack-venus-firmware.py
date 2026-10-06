#!/usr/bin/env python3
"""Repack a Windows venus.mbn so the kernel loads it without TZ relocation.

The Windows image marks its LOAD segments QCOM_MDT_RELOCATABLE (p_flags bit 27).
That makes qcom_mdt_load() call qcom_scm_pas_mem_setup(), which TZ on this
platform refuses (see HARDWARE-STATUS.md): the bootloader reserved a *fixed*
5 MB video firmware carve-out and the vendor path never relocates.

Dropping the bit and rebasing each segment's p_paddr onto the carve-out makes
the loader place the segments at exactly the same offsets while taking the
non-relocatable path, so the SCM call is not made at all.

Only the ELF header + program-header table change; the loadable segments (the
data the hash segment signs) are copied verbatim, so TZ's image authentication
still sees the original signed content.

Usage:
    repack-venus-firmware.py <in.mbn> <out.mbn> <base-address>

    repack-venus-firmware.py firmware/qcom/sc8180x/venus.mbn \
        firmware/qcom/sc8180x/venus-noreloc.mbn 0x9ffb0000
"""
import struct
import sys

PT_LOAD = 1
QCOM_MDT_RELOCATABLE = 1 << 27      # drivers/soc/qcom/mdt_loader.c


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    src, dst, base = sys.argv[1], sys.argv[2], int(sys.argv[3], 0)

    data = bytearray(open(src, "rb").read())
    e_phoff = struct.unpack_from("<I", data, 28)[0]
    e_phnum = struct.unpack_from("<H", data, 44)[0]

    loadable = []
    for i in range(e_phnum):
        off = e_phoff + i * 32
        p_type, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_flags, p_align = \
            struct.unpack_from("<8I", data, off)
        if p_type == PT_LOAD and p_filesz:
            loadable.append((i, off, p_paddr, p_memsz, p_flags))
    if not loadable:
        sys.exit("no loadable segments found")

    min_addr = min(p[2] for p in loadable)
    max_addr = max((p[2] + p[3] + 0xFFF) & ~0xFFF for p in loadable)
    print(f"segments: {len(loadable)}, {min_addr:#x}..{max_addr:#x} "
          f"(footprint {max_addr - min_addr:#x})")

    for i, off, p_paddr, p_memsz, p_flags in loadable:
        new_paddr = base + (p_paddr - min_addr)
        new_flags = p_flags & ~QCOM_MDT_RELOCATABLE
        struct.pack_into("<I", data, off + 12, new_paddr)
        struct.pack_into("<I", data, off + 24, new_flags)
        print(f"  seg {i}: paddr {p_paddr:#x} -> {new_paddr:#x}, "
              f"flags {p_flags:#010x} -> {new_flags:#010x}")
    print(f"region needed: {base:#x}..{base + (max_addr - min_addr):#x}")

    open(dst, "wb").write(data)
    print(f"wrote {dst}")


if __name__ == "__main__":
    main()
