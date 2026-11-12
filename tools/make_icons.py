#!/usr/bin/env python3
"""Draws the app icon (pink->purple gradient, white play button) as PNGs. Stdlib only."""
import math
import struct
import zlib
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "static"
TOP, BOTTOM = (255, 55, 95), (120, 60, 220)
SS = 3  # supersampling per axis


def tri_dist(px, py, pts):
    """Distance from point to triangle (0 inside)."""
    def edge(a, b):
        return (b[0] - a[0]) * (py - a[1]) - (b[1] - a[1]) * (px - a[0])
    signs = [edge(pts[i], pts[(i + 1) % 3]) for i in range(3)]
    if all(s >= 0 for s in signs) or all(s <= 0 for s in signs):
        return 0.0
    best = math.inf
    for i in range(3):
        (ax, ay), (bx, by) = pts[i], pts[(i + 1) % 3]
        dx, dy = bx - ax, by - ay
        t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
        best = min(best, math.hypot(px - ax - t * dx, py - ay - t * dy))
    return best


def draw(size):
    # Triangle in unit space, nudged right so it looks optically centred; rounded by radius r.
    r = 0.045
    pts = [(0.40, 0.30), (0.40, 0.70), (0.70, 0.50)]
    rows = []
    for y in range(size):
        row = bytearray([0])
        for x in range(size):
            cover = 0
            for sy in range(SS):
                for sx in range(SS):
                    u, v = (x + (sx + .5) / SS) / size, (y + (sy + .5) / SS) / size
                    cover += tri_dist(u, v, pts) <= r
            a = cover / (SS * SS)
            t = y / (size - 1)
            g = [TOP[i] + (BOTTOM[i] - TOP[i]) * t for i in range(3)]
            row += bytes(round(g[i] * (1 - a) + 255 * a) for i in range(3))
        rows.append(bytes(row))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b""))
    (OUT / f"icon-{size}.png").write_bytes(png)


if __name__ == "__main__":
    for s in (180, 192, 512):
        draw(s)
        print(f"wrote icon-{s}.png")
