#!/usr/bin/env python3
"""生成 1024x1024 的 App 图标（纯标准库，无第三方依赖）。

图标为温暖深色底 + 克制橙色圆形 + 白色播放三角，不含任何伪造的元数据。
可重复执行，输出确定性一致。
"""
import struct
import zlib
from pathlib import Path

SIZE = 1024
OUT = Path(__file__).resolve().parent.parent / "SPlayerRemote/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"


def blend(bg, fg, alpha):
    return tuple(round(b * (1 - alpha) + f * alpha) for b, f in zip(bg, fg))


def make_pixels():
    top = (26, 23, 26)
    bottom = (10, 10, 13)
    accent = (250, 140, 51)
    white = (255, 255, 255)

    cx, cy = SIZE / 2, SIZE / 2
    ring_inner = SIZE * 0.30
    ring_outer = SIZE * 0.36
    # 播放三角（指向右侧）
    tri = [(SIZE * 0.44, SIZE * 0.36), (SIZE * 0.44, SIZE * 0.64), (SIZE * 0.68, SIZE * 0.50)]

    def inside_triangle(x, y):
        (x1, y1), (x2, y2), (x3, y3) = tri
        d1 = (x - x2) * (y1 - y2) - (x1 - x2) * (y - y2)
        d2 = (x - x3) * (y2 - y3) - (x2 - x3) * (y - y3)
        d3 = (x - x1) * (y3 - y1) - (x3 - x1) * (y - y1)
        neg = d1 < 0 or d2 < 0 or d3 < 0
        pos = d1 > 0 or d2 > 0 or d3 > 0
        return not (neg and pos)

    rows = []
    for y in range(SIZE):
        t = y / (SIZE - 1)
        base = blend(top, bottom, t)
        row = bytearray()
        for x in range(SIZE):
            r, g, b = base
            dx, dy = x - cx, y - cy
            dist = (dx * dx + dy * dy) ** 0.5
            # 橙色圆环
            ring = 0.0
            if ring_inner <= dist <= ring_outer:
                edge = min(dist - ring_inner, ring_outer - dist)
                ring = min(1.0, max(0.0, edge / 6.0))
            if ring > 0:
                r, g, b = blend((r, g, b), accent, ring)
            # 中心圆
            if dist <= SIZE * 0.26:
                r, g, b = blend((r, g, b), accent, 0.22)
            # 白色三角
            if inside_triangle(x, y):
                r, g, b = blend((r, g, b), white, 0.96)
            row += bytes((r, g, b, 255))
        rows.append(bytes(row))
    return rows


def write_png(path, rows):
    raw = b"".join(b"\x00" + r for r in rows)

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)


if __name__ == "__main__":
    write_png(OUT, make_pixels())
    print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")
