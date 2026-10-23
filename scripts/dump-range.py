#!/usr/bin/env python3
"""Prints part of a kernel memory dump, gzip+base64-encoded, plus the C strings its 64-bit
words point to, for decoding elsewhere.

    dump-range.py kmem.bin 0xfffffff006000000 0xfffffff00985c000 4096

Output: "== RANGE <va> <length>", base64 lines, "== END", then "ptr <slot va> -> <target>: <string>"
for each word that points into the dump at printable text.
"""
import base64
import gzip
import struct
import sys

dump, base, va, length = sys.argv[1], int(sys.argv[2], 0), int(sys.argv[3], 0), int(sys.argv[4], 0)
data = open(dump, "rb").read()
chunk = data[va - base:va - base + length]
print(f"== RANGE {va:#x} {len(chunk)}")
text = base64.b64encode(gzip.compress(chunk, 9)).decode()
for k in range(0, len(text), 120):
    print(text[k:k + 120])
print("== END")
for i in range(0, len(chunk) - 7, 8):
    p = struct.unpack_from("<Q", chunk, i)[0] | 0xFFFF000000000000   # strip any PAC/tag bits
    o = p - base
    if 0 <= o < len(data):
        end = data.find(b"\0", o, o + 64)
        s = data[o:end] if end > o else b""
        raw = data[o:o + 16].hex()
        shown = s.decode("latin1") if s and all(32 <= c < 127 for c in s) else ""
        print(f"ptr {va + i:#x} -> {p:#x}: {raw} {shown!r}")
