#!/usr/bin/env python3
"""Sends touches to a running machine the way the app does (VNC pointer events) and reports
whether the screen reacts (CI).

Waits until the emulated screen shows more than the boot logo, then taps the middle, swipes up
from the bottom edge and presses Home (the app's keysym), taking a screendump after each and
printing how much of the screen changed.

    scripts/ci-touch-test.py [--monitor 1235] [--vnc 5901] [--wait 1500] [--out touch]
"""
import argparse
import socket
import struct
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
            return s
        except OSError:
            time.sleep(2)
    sys.exit(f"port {port} not reachable")


def read_ppm(path):
    data = open(path, "rb").read()
    parts = data.split(b"\n", 3)
    w, h = map(int, parts[1].split())
    return w, h, parts[3]


def lit(pixels, step=97):
    n = len(pixels) // 3
    on = sum(1 for i in range(0, n, step) if max(pixels[3 * i:3 * i + 3]) > 24)
    return on / (n // step + 1)


def changed(a, b, step=97):
    n = min(len(a), len(b)) // 3
    diff = sum(1 for i in range(0, n, step)
               if abs(a[3 * i] - b[3 * i]) + abs(a[3 * i + 1] - b[3 * i + 1]) + abs(a[3 * i + 2] - b[3 * i + 2]) > 30)
    return diff / (n // step + 1)


class VNC:
    """Just enough RFB 3.8 to send input: no authentication, shared session."""

    def __init__(self, port, wait):
        self.s = connect(port, wait)
        self.s.settimeout(10)
        self.s.recv(12)
        self.s.sendall(b"RFB 003.008\n")
        count = self.s.recv(1)[0]
        self.s.recv(count)
        self.s.sendall(b"\x01")
        self.s.recv(4)
        self.s.sendall(b"\x01")
        head = self.s.recv(24)
        self.w, self.h = struct.unpack(">HH", head[:4])
        name_len = struct.unpack(">I", head[20:24])[0]
        self.s.recv(name_len)
        print(f"== VNC {self.w}x{self.h}")

    def pointer(self, x, y, pressed):
        self.s.sendall(struct.pack(">BBHH", 5, 1 if pressed else 0, max(0, min(x, self.w - 1)), max(0, min(y, self.h - 1))))

    def key(self, keysym):
        for down in (1, 0):
            self.s.sendall(struct.pack(">BBxxI", 4, down, keysym))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--monitor", type=int, default=1235)
    ap.add_argument("--vnc", type=int, default=5901)
    ap.add_argument("--wait", type=float, default=1500, help="seconds to wait for the screen")
    ap.add_argument("--out", default="touch")
    a = ap.parse_args()

    mon = connect(a.monitor, 900)
    query(mon, "")
    start = time.time()
    shot = 0

    def dump(name):
        nonlocal shot
        shot += 1
        path = f"{a.out}-{shot:02d}-{name}.ppm"
        query(mon, f"screendump {path}")
        time.sleep(2)
        return path

    while True:
        path = dump("wait")
        try:
            frac = lit(read_ppm(path)[2])
        except Exception:
            frac = 0
        print(f"== {time.time() - start:.0f} s: {100 * frac:.1f} % lit")
        if frac > 0.3:
            break
        if time.time() - start > a.wait:
            sys.exit("screen never came up")
        time.sleep(20)

    print(query(mon, "info mice"))
    vnc = VNC(a.vnc, 60)
    time.sleep(30)                       # let the first screen settle
    before = read_ppm(dump("before"))[2]

    def report(name, wait):
        nonlocal before
        time.sleep(wait)
        after = read_ppm(dump(name))[2]
        print(f"== after {name}: {100 * changed(before, after):.1f} % of the screen changed, {100 * lit(after):.1f} % lit")
        before = after

    def ascii(pixels, w, h, cols=48, rows=40):
        """A coarse picture of the screen, dark to light."""
        ramp = " .:-=+*#%@"
        for r in range(rows):
            line = ""
            for c in range(cols):
                i = (int((r + 0.5) * h / rows) * w + int((c + 0.5) * w / cols)) * 3
                line += ramp[min(9, sum(pixels[i:i + 3]) * 10 // 766)]
            print("  |" + line + "|")

    def show(name):
        w, h, px = read_ppm(dump(name))
        ascii(px, w, h)

    def swipe(x0, y0, x1, y1, seconds, steps=20):
        vnc.pointer(x0, y0, True)
        for i in range(1, steps + 1):
            time.sleep(seconds / steps)
            vnc.pointer(x0 + (x1 - x0) * i // steps, y0 + (y1 - y0) * i // steps, i < steps)

    report("idle", 20)                   # what changes on its own (the hello animation)
    show("start")
    w, h = vnc.w, vnc.h
    swipe(w // 2, h - 4, w // 2, h * 55 // 100, 0.4)
    report("fast-swipe-up", 40)
    swipe(w // 2, h - 4, w // 2, h * 40 // 100, 2.0)
    report("slow-swipe-up", 40)
    show("after-swipes")
    # The accessibility (i) button at the bottom right of the Hello screen.
    x, y = w * 895 // 1000, h * 953 // 1000
    vnc.pointer(x, y, True); time.sleep(0.2); vnc.pointer(x, y, False)
    report("tap-info", 40)
    show("after-tap")
    vnc.key(0xFFC2)                      # F5: the side button
    report("side-button", 40)
    show("end")

if __name__ == "__main__":
    main()
