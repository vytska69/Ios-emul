#!/usr/bin/env python3
"""Prints, gzip+base64-encoded, the kernel code around the first reference to a log string and
the strings around it, so a whole kext can be disassembled off the CI machine.

    dump-around-string.py kmem.bin 0xfffffff006000000 "failed to create refkey" [code KiB] [string KiB]

Output: "== CODE <va> <length>" / "== STRINGS <va> <length>" each followed by base64 lines and
"== END". Decode with `base64 -d | gunzip`; the code is raw arm64 at <va>.
"""
import base64
import gzip
import struct
import sys


def sext(value, bits):
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


def first_xref(words, base, target, window=8):
    page = target & ~0xFFF
    for i, insn in enumerate(words):
        if insn & 0x9F000000 != 0x90000000:
            continue
        pc = base + 4 * i
        imm = sext((((insn >> 5) & 0x7FFFF) << 2) | ((insn >> 29) & 3), 21) << 12
        if (pc & ~0xFFF) + imm != page:
            continue
        reg = insn & 31
        for j in range(i + 1, min(i + 1 + window, len(words))):
            use = words[j]
            if (use >> 5) & 31 != reg or use & 0xFF800000 != 0x91000000:
                continue
            if page + (((use >> 10) & 0xFFF) << (12 if use & (1 << 22) else 0)) == target:
                return pc
    return None


def emit(kind, data, base, start, length):
    lo = max(0, start - base)
    chunk = data[lo:lo + length]
    print(f"== {kind} {base + lo:#x} {len(chunk)}")
    text = base64.b64encode(gzip.compress(chunk, 9)).decode()
    for k in range(0, len(text), 120):
        print(text[k:k + 120])
    print("== END")


def main():
    dump, base, text = sys.argv[1], int(sys.argv[2], 0), sys.argv[3]
    code_kib = int(sys.argv[4]) if len(sys.argv) > 4 else 256
    str_kib = int(sys.argv[5]) if len(sys.argv) > 5 else 64
    data = open(dump, "rb").read()
    off = data.find(text.encode())
    if off < 0:
        print(f"== {text!r}: not found")
        return
    while off > 0 and data[off - 1] != 0:
        off -= 1
    va = base + off
    words = struct.unpack("<%dI" % (len(data) // 4), data[: len(data) // 4 * 4])
    pc = first_xref(words, base, va)
    print(f"== string {text!r} at {va:#x}, first reference at {pc:#x}" if pc else f"== string at {va:#x}, no reference")
    if pc:
        emit("CODE", data, base, pc - code_kib * 512, code_kib * 1024)
    emit("STRINGS", data, base, va - str_kib * 512, str_kib * 1024)


if __name__ == "__main__":
    main()
