#!/usr/bin/env python3
"""Compares two render dumps (RenderDump in NexusCanvasTests) file by file.

Usage: scripts/compare-renders.py BEFORE AFTER

Raw pixel files (.rgba: an 8-byte width/height header, then RGBA8) are compared pixel by
pixel; everything else (SVG, HTML) byte for byte. Prints each file that differs and exits
non-zero if any does, or if either folder has a file the other lacks.
"""
import os
import struct
import sys


def main(before: str, after: str) -> int:
    a = set(os.listdir(before))
    b = set(os.listdir(after))
    bad = 0
    for name in sorted(a ^ b):
        print(f"only in {'before' if name in a else 'after'}: {name}")
        bad += 1
    same = 0
    for name in sorted(a & b):
        x = open(os.path.join(before, name), "rb").read()
        y = open(os.path.join(after, name), "rb").read()
        if x == y:
            same += 1
            continue
        bad += 1
        if name.endswith(".rgba") and len(x) >= 8 and len(y) >= 8:
            wx, hx = struct.unpack("<II", x[:8])
            wy, hy = struct.unpack("<II", y[:8])
            if (wx, hx) != (wy, hy):
                print(f"{name}: size {wx}x{hx} -> {wy}x{hy}")
                continue
            px = x[8:]
            py = y[8:]
            diff = 0
            worst = 0
            for i in range(0, len(px), 4):
                if px[i : i + 4] != py[i : i + 4]:
                    diff += 1
                    worst = max(worst, max(abs(px[i + k] - py[i + k]) for k in range(4)))
            print(f"{name}: {diff} of {wx * hx} pixels differ, by up to {worst}")
        else:
            print(f"{name}: {len(x)} -> {len(y)} bytes, differs")
    print(f"{same} identical, {bad} differ or missing")
    return 1 if bad else 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2]))
