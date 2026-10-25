#!/usr/bin/env python3
"""Samples where the emulated CPUs spend their time while a machine runs (CI).

Connects to the QEMU monitor every `interval` seconds and records, per vCPU, whether it is
halted (idle), in the kernel (EL1/EL2) or in user space (EL0), with its PC. At the end it prints
the shares and the most frequent PCs of each kind, for symbolication.

    scripts/ci-sample-pc.py [--port 1235] [--seconds 600] [--interval 0.5] [--out samples.txt]
"""
import argparse
import collections
import re
import socket
import sys
import time


def query(sock, command, timeout=5.0):
    sock.sendall(command.encode() + b"\n")
    data = b""
    end = time.time() + timeout
    while time.time() < end:
        try:
            chunk = sock.recv(65536)
        except socket.timeout:
            continue
        if not chunk:
            break
        data += chunk
        if data.rstrip().endswith(b"(qemu)"):
            break
    return data.decode(errors="replace")


def connect(port, wait):
    end = time.time() + wait
    while time.time() < end:
        try:
            s = socket.create_connection(("127.0.0.1", port), timeout=2)
            s.settimeout(0.5)
            query(s, "")          # banner and first prompt
            return s
        except OSError:
            time.sleep(1)
    sys.exit("monitor not reachable")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=1235)
    ap.add_argument("--seconds", type=float, default=600)
    ap.add_argument("--interval", type=float, default=0.5)
    ap.add_argument("--wait", type=float, default=900, help="seconds to wait for the monitor")
    ap.add_argument("--out", default="samples.txt")
    a = ap.parse_args()

    sock = connect(a.port, a.wait)
    states = collections.Counter()
    pcs = {"EL0": collections.Counter(), "EL1": collections.Counter()}
    timeline = []
    start = time.time()
    with open(a.out, "w") as out:
        while time.time() - start < a.seconds:
            t = time.time() - start
            cpus = query(sock, "info cpus")
            halted = {int(m.group(1)): bool(m.group(2))
                      for m in re.finditer(r"CPU #(\d+):.*?(\(halted\))?\s*$", cpus, re.M)}
            regs = query(sock, "info registers -a")
            if not regs.strip():
                break
            row = []
            for block in re.split(r"(?=CPU#\d+)", regs):
                m = re.match(r"CPU#(\d+)", block)
                if not m:
                    continue
                cpu = int(m.group(1))
                pc = re.search(r"PC=([0-9a-f]{16})", block)
                el = re.search(r"EL([0-3])[th]", block)
                if not pc or not el:
                    continue
                pcv = int(pc.group(1), 16)
                if halted.get(cpu):
                    kind = "idle"
                elif el.group(1) == "0":
                    kind = "EL0"
                else:
                    kind = "EL1"
                states[kind] += 1
                if kind in pcs:
                    pcs[kind][pcv & ~0xF] += 1
                row.append(f"{cpu}:{kind}:{pcv:x}")
            out.write(f"{t:.1f} " + " ".join(row) + "\n")
            timeline.append((t, row))
            time.sleep(a.interval)

    total = sum(states.values()) or 1
    print(f"== {total} CPU samples over {time.time() - start:.0f} s")
    for kind in ("EL0", "EL1", "idle"):
        print(f"{kind:5s} {states[kind]:7d}  {100 * states[kind] / total:5.1f} %")
    busy = states["EL0"] + states["EL1"]
    if busy:
        print(f"of busy time: user space {100 * states['EL0'] / busy:.1f} %, kernel {100 * states['EL1'] / busy:.1f} %")
    # Shares per minute, to see how they change over the boot.
    per_min = collections.defaultdict(collections.Counter)
    for t, row in timeline:
        for entry in row:
            per_min[int(t // 60)][entry.split(":")[1]] += 1
    for minute in sorted(per_min):
        c = per_min[minute]
        n = sum(c.values()) or 1
        print(f"min {minute:3d}: EL0 {100 * c['EL0'] / n:5.1f} %  EL1 {100 * c['EL1'] / n:5.1f} %  idle {100 * c['idle'] / n:5.1f} %")
    for kind in ("EL0", "EL1"):
        print(f"== top {kind} PCs")
        for pc, n in pcs[kind].most_common(25):
            print(f"{pc:#x} {n}")


if __name__ == "__main__":
    main()
