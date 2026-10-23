#!/usr/bin/env python3
"""Finds the arm64 code that reads, writes or takes the address of a kernel global.

Works on a raw memory dump (e.g. QEMU `pmemsave` of the kernel's physical range), so it needs no
decompressed kernelcache: give the dump, the virtual address its first byte maps to and the target.
Each hit is an ADRP to the target's page followed (within a few instructions) by an ADD/LDR/STR
on the same register that lands exactly on the target. Prints the hit with surrounding words so
they can be disassembled elsewhere.

    xref.py kmem.bin 0xfffffff006000000 0xfffffff0098114a8 [--context 24]
"""
import argparse
import struct


def sext(value, bits):
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dump")
    ap.add_argument("base", type=lambda v: int(v, 0))
    ap.add_argument("target", type=lambda v: int(v, 0))
    ap.add_argument("--context", type=int, default=24, help="words printed before each hit")
    ap.add_argument("--window", type=int, default=8, help="instructions searched after the ADRP")
    args = ap.parse_args()

    data = open(args.dump, "rb").read()
    words = struct.unpack("<%dI" % (len(data) // 4), data[: len(data) // 4 * 4])
    page = args.target & ~0xFFF
    hits = 0
    for i, insn in enumerate(words):
        if insn & 0x9F000000 != 0x90000000:
            continue
        pc = args.base + 4 * i
        imm = sext((((insn >> 5) & 0x7FFFF) << 2) | ((insn >> 29) & 3), 21) << 12
        if (pc & ~0xFFF) + imm != page:
            continue
        reg = insn & 31
        for j in range(i + 1, min(i + 1 + args.window, len(words))):
            use = words[j]
            rn = (use >> 5) & 31
            if rn != reg:
                continue
            if use & 0xFF800000 == 0x91000000:  # ADD (immediate), 64-bit
                offset = ((use >> 10) & 0xFFF) << (12 if use & (1 << 22) else 0)
                kind = "add"
            elif use & 0x3B000000 == 0x39000000:  # LDR/STR (unsigned immediate)
                size = use >> 30
                offset = ((use >> 10) & 0xFFF) << size
                kind = "ldr" if use & (1 << 22) else "str"
            else:
                continue
            if page + offset == args.target:
                hits += 1
                use_pc = args.base + 4 * j
                print(f"== {kind} at {use_pc:#x} (adrp at {pc:#x})")
                start = max(0, i - args.context)
                for k in range(start, min(len(words), j + 8), 4):
                    row = " ".join(f"{w:#010x}" for w in words[k : min(k + 4, j + 8)])
                    print(f"  | {args.base + 4 * k:016x}: {row}")
                break
    print(f"== {hits} reference(s) to {args.target:#x}")


if __name__ == "__main__":
    main()
