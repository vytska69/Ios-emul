#!/usr/bin/env python3
"""Summarises the DeviceTree of the newest IPSW for each product type, without downloading the IPSW.

Only the ZIP central directory, BuildManifest.plist and the DeviceTree member are fetched with HTTP
range requests (a few MB instead of several GB). The output is a plain-text hardware inventory:
node path, `compatible`, register block count and size. That is the spec sheet a new machine model
is written against, and it diffs cleanly between SoCs.

    pip install remotezip
    scripts/dt-survey.py iPhone13,2 iPad13,4 ... --out research/devicetrees
"""
import argparse
import json
import plistlib
import struct
import sys
import urllib.request
from pathlib import Path

from remotezip import RemoteZip


def der(data, i=0):
    """Returns (tag, value, raw TLV bytes, next offset) for the element at i."""
    start, tag, length = i, data[i], data[i + 1]
    i += 2
    if length & 0x80:
        n = length & 0x7F
        length = int.from_bytes(data[i:i + n], "big")
        i += n
    return tag, data[i:i + length], data[start:i + length], i + length


def im4p_payload(data):
    _, body, _, _ = der(data)
    items, i = [], 0
    while i < len(body):
        tag, value, raw, i = der(body, i)
        items.append((tag, value, raw))
    if items and items[0][1] == b"IMG4":
        return im4p_payload(items[1][2])
    if not items or items[0][1] != b"IM4P":
        raise ValueError("not an IM4P")
    payload = items[3][1]
    if any(tag == 0x04 for tag, _, _ in items[4:]):
        raise ValueError("encrypted DeviceTree")
    if payload[:4] in (b"bvx2", b"bvx1", b"bvxn", b"bvx-"):
        import liblzfse  # pip install pyliblzfse
        payload = liblzfse.decompress(payload)
    return payload


def parse_node(data, off):
    nprops, nchildren = struct.unpack_from("<II", data, off)
    off += 8
    props = {}
    for _ in range(nprops):
        name = data[off:off + 32].split(b"\0", 1)[0].decode(errors="replace")
        length = struct.unpack_from("<I", data, off + 32)[0] & 0x7FFFFFFF
        off += 36
        props[name] = data[off:off + length]
        off += (length + 3) & ~3
    children = []
    for _ in range(nchildren):
        child, off = parse_node(data, off)
        children.append(child)
    return {"props": props, "children": children}, off


def text(value):
    return [s.decode(errors="replace") for s in value.split(b"\0") if s]


def walk(node, path, out, root=True):
    name = text(node["props"].get("name", b"?"))[0] if node["props"].get("name") else "?"
    here = "" if root else f"{path}/{name}"
    compat = ",".join(text(node["props"].get("compatible", b"")))
    reg = node["props"].get("reg", b"")
    regs = ""
    if reg:
        # arm-io children use (u64 addr, u64 size) pairs; report count and total size
        pairs = len(reg) // 16
        size = sum(struct.unpack_from("<Q", reg, 16 * k + 8)[0] for k in range(pairs)) if pairs else 0
        regs = f" reg={pairs}x total=0x{size:x}"
    if here:
        out.append(f"{here}  [{compat}]{regs}".rstrip())
    for child in node["children"]:
        walk(child, here, out, root=False)


def ipsw_me(product):
    with urllib.request.urlopen(f"https://api.ipsw.me/v4/device/{product}?type=ipsw") as r:
        info = json.load(r)
    boards = [b["boardconfig"].lower() for b in info.get("boards", [])]
    return info["firmwares"][0], boards  # newest first


def survey(product, outdir):
    fw, boards = ipsw_me(product)
    with RemoteZip(fw["url"]) as z:
        manifest = plistlib.loads(z.read("BuildManifest.plist"))
        # A multi-device IPSW has identities for every board; take this product's erase install.
        idents = [i for i in manifest["BuildIdentities"]
                  if i["Info"].get("DeviceClass", "").lower() in boards and "DeviceTree" in i["Manifest"]]
        if not idents:
            raise ValueError(f"no build identity for boards {boards}")
        ident = next((i for i in idents if i["Info"].get("RestoreBehavior") == "Erase"), idents[0])
        board = ident["Info"]["DeviceClass"].lower()
        dt = ident["Manifest"]["DeviceTree"]["Info"]["Path"]
        tree, _ = parse_node(im4p_payload(z.read(dt)), 0)
    lines = []
    walk(tree, "", lines)
    soc = text(tree["props"].get("compatible", b""))
    header = [f"# {product} {board} iOS {fw['version']} ({fw['buildid']})",
              f"# root compatible: {', '.join(soc)}",
              f"# {len(lines)} nodes", ""]
    path = Path(outdir) / f"{product}-{board}-{fw['buildid']}.txt"
    path.write_text("\n".join(header + lines) + "\n")
    print(f"{product}: {path} ({len(lines)} nodes)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("products", nargs="+")
    ap.add_argument("--out", default="research/devicetrees")
    args = ap.parse_args()
    Path(args.out).mkdir(parents=True, exist_ok=True)
    failed = 0
    for p in args.products:
        try:
            survey(p, args.out)
        except Exception as e:  # keep going: one odd firmware should not hide the rest
            failed += 1
            print(f"{p}: FAILED {e}", file=sys.stderr)
    sys.exit(1 if failed == len(args.products) else 0)


if __name__ == "__main__":
    main()
