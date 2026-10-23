#!/usr/bin/env python3
"""Finds C strings in a kernel memory dump and the code that takes their address.

    find-string-xrefs.py kmem.bin 0xfffffff006000000 "Failed to write effaceable" ["other" ...]

For each string, prints its virtual address(es) and runs xref.py on each, so the functions that
print a log message can be located and disassembled.
"""
import os
import subprocess
import sys

dump, base = sys.argv[1], int(sys.argv[2], 0)
data = open(dump, "rb").read()
here = os.path.dirname(os.path.abspath(__file__))
for text in sys.argv[3:]:
    needle = text.encode()
    off = data.find(needle)
    if off < 0:
        print(f"== {text!r}: not found")
        continue
    while off >= 0:
        # Back up to the start of the C string the text is part of.
        start = off
        while start > 0 and data[start - 1] != 0:
            start -= 1
        va = base + start
        print(f"== {text!r} at {va:#x} (string starts {off - start} bytes earlier)")
        sys.stdout.flush()
        subprocess.run([sys.executable, os.path.join(here, "xref.py"), dump, hex(base), hex(va),
                        "--context", "48"])
        off = data.find(needle, off + 1)
