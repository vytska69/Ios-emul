#!/usr/bin/env python3
"""Summarises an iOS stackshot report (bug_type 288, e.g. stacks+com.apple.datamigrator-*.ips):
for each process whose name contains one of the given words, every thread's state, what it waits
on, and its user and kernel frames as image+offset.

    stackshot-summary.py report.ips locationd migrat [--addresses]
"""
import json
import sys

path, words = sys.argv[1], [w.lower() for w in sys.argv[2:]]
text = open(path, errors="replace").read()
body = json.loads(text[text.index("\n") + 1:])          # first line is the report header
print("reason:", body.get("reason"))
images = body.get("binaryImages", [])


addresses = "--addresses" in words
words = [w for w in words if w != "--addresses"]


def frame(f):
    index, offset = f[0], f[1]
    if 0 <= index < len(images):
        image = images[index]
        name = image[2] if len(image) > 2 and image[2] else image[0]
        text = f"{name.split('/')[-1]}+{offset:#x}"
        # With --addresses, shared-cache frames also as unslid addresses (for `ipsw dyld a2s`).
        if addresses and name == "S" and len(image) > 1 and isinstance(image[1], int):
            text += f" @{image[1] + offset:#x}"
        return text
    return f"?{index}+{offset:#x}"


for pid, proc in sorted(body.get("processByPid", {}).items(), key=lambda p: int(p[0])):
    name = proc.get("procname", "?")
    if words and not any(w in name.lower() for w in words):
        continue
    print(f"== pid {pid} {name}")
    for tid, thread in proc.get("threadById", {}).items():
        waits = thread.get("waitInfo") or thread.get("waitEvent")
        print(f"  thread {tid} {thread.get('name', '')} {'/'.join(thread.get('state', []))} wait={waits}")
        if "userFrames" not in thread and "kernelFrames" not in thread:
            print("     raw", json.dumps(thread)[:700])
        for f in thread.get("userFrames", [])[:14]:
            print("     u", frame(f))
        for f in thread.get("kernelFrames", [])[:6]:
            print("     k", frame(f))
