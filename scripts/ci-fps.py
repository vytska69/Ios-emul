#!/usr/bin/env python3
"""Frame rate of the emulated iPhone's screen while a finger drags across it (CI).

Opens a second, shared VNC session that only reads framebuffer updates, while the first one drags
a finger back and forth on the home screen for a few seconds, and prints how many screen updates
QEMU sent per second. The home screen follows the finger, so every update is a frame iOS drew:
this measures how fast the emulated phone renders while it is being used.

    python3 scripts/ci-fps.py [--vnc 5901] [--seconds 10] [--rounds 3]
"""
import argparse
import importlib.util
import math
import os
import socket
import struct
import threading
import time

spec = importlib.util.spec_from_file_location("touch", os.path.join(os.path.dirname(__file__), "ci-touch-test.py"))
touch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(touch)


def recv_exact(s, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = s.recv(min(n - len(buf), 1 << 20))
        if not chunk:
            raise ConnectionError("VNC closed")
        buf += chunk
    return bytes(buf)


class FrameCounter(threading.Thread):
    """Counts framebuffer updates on its own shared VNC session."""

    def __init__(self, port):
        super().__init__(daemon=True)
        s = touch.connect(port, 60)
        s.settimeout(10)
        recv_exact(s, 12)
        s.sendall(b"RFB 003.008\n")
        count = recv_exact(s, 1)[0]
        recv_exact(s, count)
        s.sendall(b"\x01")
        recv_exact(s, 4)
        s.sendall(b"\x01")
        head = recv_exact(s, 24)
        self.w, self.h = struct.unpack(">HH", head[:4])
        self.bpp = head[4] // 8
        recv_exact(s, struct.unpack(">I", head[20:24])[0])
        s.sendall(struct.pack(">BxHi", 2, 1, 0))  # SetEncodings: raw only
        self.s = s
        self.frames = 0
        self.stop = False

    def run(self):
        s = self.s
        s.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, self.w, self.h))
        while not self.stop:
            try:
                kind = recv_exact(s, 1)[0]
            except (socket.timeout, ConnectionError):
                continue
            if kind == 0:
                _, rects = struct.unpack(">xH", recv_exact(s, 3))
                for _ in range(rects):
                    x, y, w, h, enc = struct.unpack(">HHHHi", recv_exact(s, 12))
                    if enc == 0:
                        recv_exact(s, w * h * self.bpp)
                self.frames += 1
                s.sendall(struct.pack(">BBHHHH", 3, 1, 0, 0, self.w, self.h))
            elif kind == 1:
                _, n = struct.unpack(">xHH", recv_exact(s, 5))
                recv_exact(s, 6 * n)
            elif kind == 2:
                pass
            elif kind == 3:
                recv_exact(s, 3)
                recv_exact(s, struct.unpack(">I", recv_exact(s, 4))[0])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vnc", type=int, default=5901)
    ap.add_argument("--seconds", type=float, default=10)
    ap.add_argument("--rounds", type=int, default=3)
    args = ap.parse_args()

    counter = FrameCounter(args.vnc)
    counter.start()
    vnc = touch.VNC(args.vnc, 60)
    W, H = vnc.w, vnc.h
    time.sleep(3)
    results = []
    for r in range(args.rounds):
        f0 = counter.frames
        time.sleep(args.seconds)
        idle = (counter.frames - f0) / args.seconds
        x0, y = W // 2, H // 2
        vnc.pointer(x0, y, True)
        f0, t0 = counter.frames, time.time()
        while time.time() - t0 < args.seconds:
            t = time.time() - t0
            vnc.pointer(int(x0 + W * 0.3 * math.sin(2 * math.pi * 0.5 * t)), y, True)
            time.sleep(0.016)
        fps = (counter.frames - f0) / (time.time() - t0)
        vnc.pointer(x0, y, False)
        results.append(fps)
        print(f"== fps round {r + 1}: dragging {fps:.1f} frames/s (idle before {idle:.1f})", flush=True)
        time.sleep(5)
    counter.stop = True
    print(f"== fps median {sorted(results)[len(results) // 2]:.1f} frames/s", flush=True)


if __name__ == "__main__":
    main()
