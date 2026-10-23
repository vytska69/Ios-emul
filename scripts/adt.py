#!/usr/bin/env python3
"""Prints a raw Apple device tree (as iBoot or QEMU hands it to the kernel), e.g. from a memory dump.

    adt.py dt.bin [/cpus]

Each node is: property count, child count (u32 each), then properties (32-byte name, u32 length
whose top bit is a flag, value padded to 4 bytes), then the children.
"""
import struct
import sys


def parse(data, off=0):
    nprops, nchildren = struct.unpack_from("<II", data, off)
    off += 8
    props = {}
    for _ in range(nprops):
        name = data[off:off + 32].split(b"\0", 1)[0].decode(errors="replace")
        length = struct.unpack_from("<I", data, off + 32)[0] & 0x7FFFFFFF
        props[name] = data[off + 36:off + 36 + length]
        off += 36 + ((length + 3) & ~3)
    children = []
    for _ in range(nchildren):
        child, off = parse(data, off)
        children.append(child)
    return (props, children), off


def show(value):
    text = value.rstrip(b"\0")
    if text and all(32 <= b < 127 for b in text):
        return text.decode()
    if len(value) in (4, 8):
        return f"{int.from_bytes(value, 'little'):#x} ({value.hex()})"
    return value[:48].hex() + ("…" if len(value) > 48 else "")


def dump(node, depth=0):
    props, children = node
    name = show(props.get("name", b"?"))
    print("  " * depth + name + "/")
    for key, value in props.items():
        if key != "name":
            print("  " * (depth + 1) + f"{key} = {show(value)} [{len(value)}]")
    for child in children:
        dump(child, depth + 1)


def find(node, parts):
    if not parts:
        return node
    for child in node[1]:
        if show(child[0].get("name", b"")) == parts[0]:
            return find(child, parts[1:])
    return None


root, _ = parse(open(sys.argv[1], "rb").read())
path = sys.argv[2] if len(sys.argv) > 2 else "/"
node = find(root, [p for p in path.split("/") if p])
if node is None:
    sys.exit(f"no node {path}")
dump(node)
