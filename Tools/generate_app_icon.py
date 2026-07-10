#!/usr/bin/env python3
"""Generate the SuperIsland macOS AppIcon.appiconset without third-party deps."""

from __future__ import annotations

import json
import math
import os
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ICONSET = ROOT / "SuperIsland" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"

IMAGES = [
    ("16x16", "1x", 16, "AppIcon-16.png"),
    ("16x16", "2x", 32, "AppIcon-16@2x.png"),
    ("32x32", "1x", 32, "AppIcon-32.png"),
    ("32x32", "2x", 64, "AppIcon-32@2x.png"),
    ("128x128", "1x", 128, "AppIcon-128.png"),
    ("128x128", "2x", 256, "AppIcon-128@2x.png"),
    ("256x256", "1x", 256, "AppIcon-256.png"),
    ("256x256", "2x", 512, "AppIcon-256@2x.png"),
    ("512x512", "1x", 512, "AppIcon-512.png"),
    ("512x512", "2x", 1024, "AppIcon-512@2x.png"),
]


def clamp(v: float, lo: float = 0.0, hi: float = 1.0) -> float:
    return max(lo, min(hi, v))


def mix(a: tuple[float, float, float], b: tuple[float, float, float], t: float) -> tuple[float, float, float]:
    return tuple(a[i] * (1 - t) + b[i] * t for i in range(3))


def over(dst: tuple[float, float, float, float], src: tuple[float, float, float, float]) -> tuple[float, float, float, float]:
    sr, sg, sb, sa = src
    dr, dg, db, da = dst
    out_a = sa + da * (1 - sa)
    if out_a <= 0:
        return (0, 0, 0, 0)
    return (
        (sr * sa + dr * da * (1 - sa)) / out_a,
        (sg * sa + dg * da * (1 - sa)) / out_a,
        (sb * sa + db * da * (1 - sa)) / out_a,
        out_a,
    )


def rounded_rect_alpha(x: float, y: float, cx: float, cy: float, w: float, h: float, r: float, feather: float) -> float:
    px = abs(x - cx) - (w / 2 - r)
    py = abs(y - cy) - (h / 2 - r)
    qx = max(px, 0)
    qy = max(py, 0)
    outside = math.sqrt(qx * qx + qy * qy)
    inside = min(max(px, py), 0)
    dist = outside + inside - r
    return clamp(0.5 - dist / max(0.001, feather))


def sample_icon(x: float, y: float) -> tuple[int, int, int, int]:
    # Normalized 1024-unit drawing coordinates.
    s = 1024.0
    feather = 1.2
    icon_alpha = rounded_rect_alpha(x, y, 512, 512, 912, 912, 206, feather)
    if icon_alpha <= 0:
        return (0, 0, 0, 0)

    t = clamp((x * 0.58 + y * 0.82) / s)
    bg = mix((0.082, 0.088, 0.184), (0.008, 0.010, 0.028), t)
    bg = mix(bg, (0.035, 0.042, 0.092), clamp(1 - abs(t - 0.42) * 2))

    violet = math.exp(-(((x - 404) / 560) ** 2 + ((y - 260) / 500) ** 2))
    color = mix(bg, (0.25, 0.19, 0.44), 0.23 * violet)
    out = (color[0], color[1], color[2], icon_alpha)

    # A restrained under-glow: enough to separate the matte island from the
    # background, without neon rings or decorative marks.
    glow = math.exp(-(((x - 512) / 245) ** 2 + ((y - 604) / 70) ** 2))
    out = over(out, (0.43, 0.49, 1.0, glow * 0.12 * icon_alpha))
    core_glow = math.exp(-(((x - 512) / 184) ** 2 + ((y - 604) / 42) ** 2))
    out = over(out, (0.37, 0.40, 0.92, core_glow * 0.035 * icon_alpha))

    # Single core symbol: a quiet Mac notch / island capsule.
    shadow = rounded_rect_alpha(x, y, 512, 496, 476, 178, 89, 2.0)
    out = over(out, (0, 0, 0, shadow * 0.42 * icon_alpha))
    a = rounded_rect_alpha(x, y, 512, 473, 440, 166, 83, 1.2)
    capsule = mix((0.004, 0.006, 0.020), (0.020, 0.026, 0.055), clamp((x - 292) / 440))
    out = over(out, (*capsule, a * icon_alpha))
    inner = rounded_rect_alpha(x, y, 512, 473, 372, 98, 49, 1.0)
    out = over(out, (0.062, 0.074, 0.136, inner * 0.76 * icon_alpha))

    rim = rounded_rect_alpha(x, y, 512, 473, 440, 166, 83, 1.0) * (1 - rounded_rect_alpha(x, y, 512, 473, 434, 160, 80, 1.0))
    out = over(out, (1, 1, 1, rim * 0.078 * icon_alpha))

    # A barely-there base reflection, thin enough to disappear gracefully at 16px.
    dx = (x - 512) / 182
    dy = (y - 593) / 34
    base = abs(math.sqrt(dx * dx + dy * dy) - 1)
    base_alpha = clamp(1 - base * 28) * (1 if y >= 588 else 0) * 0.08
    out = over(out, (0.48, 0.52, 1.0, base_alpha * icon_alpha))

    # Subtle top highlight and edge.
    highlight = rounded_rect_alpha(x, y, 512, 512, 912, 912, 206, 1.0)
    inner = rounded_rect_alpha(x, y, 512, 512, 902, 902, 201, 1.0)
    edge = clamp(highlight * (1 - inner))
    out = over(out, (1, 1, 1, edge * 0.09 * icon_alpha))

    return tuple(int(round(clamp(v) * 255)) for v in out)


def render(size: int) -> bytes:
    # Extra samples matter most at tiny sizes; large icons render cleanly at 1x
    # and need to regenerate quickly on a stock macOS Python install.
    ss = 3 if size <= 64 else 2 if size <= 256 else 1
    rows: list[bytes] = []
    for py in range(size):
        row = bytearray()
        for px in range(size):
            acc = [0, 0, 0, 0]
            for sy in range(ss):
                for sx in range(ss):
                    x = ((px + (sx + 0.5) / ss) / size) * 1024
                    y = ((py + (sy + 0.5) / ss) / size) * 1024
                    r, g, b, a = sample_icon(x, y)
                    acc[0] += r
                    acc[1] += g
                    acc[2] += b
                    acc[3] += a
            count = ss * ss
            row.extend(int(v / count) for v in acc)
        rows.append(bytes([0]) + bytes(row))
    return b"".join(rows)


def png_chunk(kind: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def write_png(path: Path, size: int) -> None:
    raw = render(size)
    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    data = b"\x89PNG\r\n\x1a\n"
    data += png_chunk(b"IHDR", ihdr)
    data += png_chunk(b"IDAT", zlib.compress(raw, 9))
    data += png_chunk(b"IEND", b"")
    path.write_bytes(data)


def main() -> None:
    ICONSET.mkdir(parents=True, exist_ok=True)
    for _, _, _, filename in IMAGES:
        stale = ICONSET / filename
        if stale.exists():
            stale.unlink()

    images = []
    for logical_size, scale, pixels, filename in IMAGES:
        write_png(ICONSET / filename, pixels)
        images.append({
            "filename": filename,
            "idiom": "mac",
            "scale": scale,
            "size": logical_size,
        })

    contents = {
        "images": images,
        "info": {
            "author": "xcode",
            "version": 1,
        },
    }
    (ICONSET / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    os.chdir(ROOT)
    main()
