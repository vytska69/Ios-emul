#!/usr/bin/env python3
"""Whether the emulated phone plays any sound (CI).

Waits until the screen shows more than the boot logo, records the guest's audio output with the
QEMU monitor's wavcapture while pressing buttons (side button: lock and wake, which click; the
ring/silent switch; volume up, which beeps), and prints the loudest sample per second. With
--early the recording starts before the screen comes up, to also catch what plays during startup
(VoiceOver, for one, speaks as soon as SpringBoard is up).

    scripts/ci-audio-test.py [--monitor 1235] [--wait 1500] [--out audio.wav] [--early]
"""
import argparse
import os
import struct
import sys
import time
import wave

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib.util
spec = importlib.util.spec_from_file_location("touch", os.path.join(os.path.dirname(os.path.abspath(__file__)), "ci-touch-test.py"))
touch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(touch)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--monitor", type=int, default=1235)
    ap.add_argument("--wait", type=float, default=1500)
    ap.add_argument("--out", default="audio.wav")
    ap.add_argument("--early", action="store_true")
    a = ap.parse_args()

    mon = touch.connect(a.monitor, 900)
    mon.settimeout(0.5)
    touch.query(mon, "")
    start = time.time()
    out = os.path.abspath(a.out)
    marks = []
    if a.early:
        print(touch.query(mon, f"wavcapture {out} #default"))
    shot = os.path.abspath("audio-wait.ppm")
    while True:
        touch.query(mon, f"screendump {shot}")
        time.sleep(2)
        try:
            frac = touch.lit(touch.read_ppm(shot)[2])
        except Exception:
            frac = 0
        if frac > 0.3:
            break
        if time.time() - start > a.wait:
            sys.exit("screen never came up")
        time.sleep(20)
    print(f"== screen up after {time.time() - start:.0f} s")
    if a.early:
        marks.append((time.time() - start, "screen up"))
        t0 = start
    time.sleep(30)

    if not a.early:
        print(touch.query(mon, f"wavcapture {out} #default"))
        t0 = time.time()
    print(touch.query(mon, "info capture"))
    steps = [("quiet", None), ("side (lock)", "f5"), ("side (wake)", "f5"), ("ring switch", "f2"),
             ("ring switch", "f2"), ("volume up", "f4"), ("volume up", "f4"), ("volume down", "f3")]
    for name, key in steps:
        marks.append((time.time() - t0, name))
        if key:
            touch.query(mon, f"sendkey {key}")
        time.sleep(6)
    print(touch.query(mon, "stopcapture 0"))
    time.sleep(2)

    with wave.open(out) as w:
        rate, channels, width = w.getframerate(), w.getnchannels(), w.getsampwidth()
        frames = w.readframes(w.getnframes())
    print(f"== {out}: {rate} Hz, {channels} ch, {width * 8} bit, {len(frames)} bytes")
    if width != 2:
        sys.exit("unexpected sample width")
    samples = struct.unpack(f"<{len(frames) // 2}h", frames[:len(frames) // 2 * 2])
    per_second = rate * channels
    loud = 0
    for i in range(0, len(samples), per_second):
        second = i // per_second
        label = ", ".join(n for t, n in marks if int(t) == second)
        peak = max((abs(s) for s in samples[i:i + per_second]), default=0)
        loud += peak > 0
        if peak or label or not a.early:
            print(f"{second:3d} s  peak {peak:6d}  {label}")
    print(f"== {loud} of {len(samples) // per_second} seconds not silent")


if __name__ == "__main__":
    main()
