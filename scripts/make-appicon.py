#!/usr/bin/env python3
"""Generate the SysProbe app icon (blue field + white gear) and the full
AppIcon.appiconset that Xcode consumes.

Design notes
------------
* Style follows the built-in iOS 16 Settings icon: a flat-ish gear silhouette
  on a subtly graded field, nothing glossy.
* Colours are sampled from the supplied reference tile: mid blue #4C7CF8,
  with a gentle top-to-bottom grade from #6E97FD down to #4574F5.
* iOS masks the icon corners itself, so the master artwork is full-bleed
  square with no corner radius and no alpha channel.

Usage:  python make-appicon.py [output-dir]
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw

# ---------------------------------------------------------------- artwork ----

BASE = 1024          # master edge length, px
SS = 4               # supersample factor while drawing

# Field colour, taken from the reference tile.
TOP_RGB = (0x6E, 0x97, 0xFD)
BOTTOM_RGB = (0x45, 0x74, 0xF5)

# Gear geometry, expressed as a fraction of the icon edge.
CX = CY = 0.5
R_TIP = 0.316        # radius at the tooth tips
R_ROOT = R_TIP * 0.778
R_HOLE = R_TIP * 0.360
TEETH = 8
A_TIP = math.radians(10.2)   # tooth half-angle measured at the tip radius
A_ROOT = math.radians(13.5)  # tooth half-angle measured at the root radius

# Angular smoothing applied to the radius profile, in samples of a 2880-step
# sweep. This is what rounds off the tooth tips and puts a fillet in the roots.
SMOOTH_K = 16

INK = (0xFF, 0xFF, 0xFF)     # the gear itself is plain white


def smoothstep(t: float) -> float:
    t = min(1.0, max(0.0, t))
    return t * t * (3.0 - 2.0 * t)


def gear_radius(theta: float) -> float:
    """Polar radius of the gear silhouette at ``theta`` radians."""
    period = 2.0 * math.pi / TEETH
    # Fold the angle into one tooth period, centred on a tooth.
    rel = (theta + period / 2.0) % period - period / 2.0
    a = abs(rel)
    if a <= A_TIP:
        return R_TIP
    if a >= A_ROOT:
        return R_ROOT
    s = (a - A_TIP) / (A_ROOT - A_TIP)
    return R_TIP + (R_ROOT - R_TIP) * smoothstep(s)


def gear_outline(size: int, samples: int = 2880) -> list[tuple[float, float]]:
    """Closed polygon approximating the gear, in pixel coordinates."""
    c = size * CX

    # Sample the raw profile, then smooth it so the corners read as rounded
    # rather than machined.
    raw = [gear_radius(2.0 * math.pi * i / samples) for i in range(samples)]
    weights = [1.0 - abs(j) / (SMOOTH_K + 1.0) for j in range(-SMOOTH_K, SMOOTH_K + 1)]
    total = sum(weights)
    profile = [
        sum(raw[(i + j) % samples] * weights[j + SMOOTH_K]
            for j in range(-SMOOTH_K, SMOOTH_K + 1)) / total
        for i in range(samples)
    ]

    pts: list[tuple[float, float]] = []
    for i, r_frac in enumerate(profile):
        theta = 2.0 * math.pi * i / samples
        r = r_frac * size
        pts.append((c + r * math.cos(theta), c + r * math.sin(theta)))
    return pts


def build_master(size: int = BASE) -> Image.Image:
    """Render the icon at ``size`` px, RGB, fully opaque."""
    big = size * SS

    # --- gear mask -----------------------------------------------------
    mask = Image.new("L", (big, big), 0)
    draw = ImageDraw.Draw(mask)
    draw.polygon(gear_outline(big), fill=255)

    hole_r = R_HOLE * big
    c = big * CX
    draw.ellipse(
        [c - hole_r, c - hole_r, c + hole_r, c + hole_r],
        fill=0,
    )

    # --- graded field --------------------------------------------------
    ramp = Image.new("RGB", (1, 256))
    for y in range(256):
        t = y / 255.0
        ramp.putpixel(
            (0, y),
            tuple(
                round(TOP_RGB[i] + (BOTTOM_RGB[i] - TOP_RGB[i]) * t)
                for i in range(3)
            ),
        )
    field = ramp.resize((big, big), Image.BILINEAR)

    # --- composite -----------------------------------------------------
    field.paste(INK, (0, 0), mask)
    return field.resize((size, size), Image.LANCZOS)


def rounded_preview(master: Image.Image, size: int = 512, radius_frac: float = 0.2237) -> Image.Image:
    """Home-screen style preview: the system mask applied by hand."""
    radius = round(size * radius_frac)
    mask = Image.new("L", (size * 4, size * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, size * 4 - 1, size * 4 - 1], radius=radius * 4, fill=255
    )
    mask = mask.resize((size, size), Image.LANCZOS)

    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(master.resize((size, size), Image.LANCZOS), (0, 0), mask)
    return out


# ------------------------------------------------------------- appiconset ----

# Classic iPhone-only set. Bulletproof across Xcode versions.
IPHONE_SIZES: list[tuple[int, int, str]] = [
    (20, 2, "icon-20@2x.png"),
    (20, 3, "icon-20@3x.png"),
    (29, 2, "icon-29@2x.png"),
    (29, 3, "icon-29@3x.png"),
    (40, 2, "icon-40@2x.png"),
    (40, 3, "icon-40@3x.png"),
    (60, 2, "icon-60@2x.png"),
    (60, 3, "icon-60@3x.png"),
]


def contents_json() -> str:
    images = [
        {
            "filename": name,
            "idiom": "iphone",
            "scale": f"{scale}x",
            "size": f"{pt}x{pt}",
        }
        for pt, scale, name in IPHONE_SIZES
    ]
    images.append(
        {
            "filename": "icon-1024.png",
            "idiom": "ios-marketing",
            "scale": "1x",
            "size": "1024x1024",
        }
    )
    doc = {
        "images": images,
        "info": {"author": "xcode", "version": 1},
    }
    return json.dumps(doc, indent=2) + "\n"


def main() -> int:
    out_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(
        "Sources/App/Assets.xcassets/AppIcon.appiconset"
    )
    preview_path = Path(sys.argv[2]) if len(sys.argv) > 2 else None
    out_dir.mkdir(parents=True, exist_ok=True)

    master = build_master(BASE)
    master.save(out_dir / "icon-1024.png", "PNG", optimize=True)

    for pt, scale, name in IPHONE_SIZES:
        px = pt * scale
        master.resize((px, px), Image.LANCZOS).save(
            out_dir / name, "PNG", optimize=True
        )

    # 显式写 LF：在 Windows 上跑这个脚本时默认会给 JSON 塞 CRLF，之后每次
    # git status 都会看到一个"被改过"的 Contents.json。
    (out_dir / "Contents.json").write_text(contents_json(), encoding="utf-8", newline="\n")

    # A separate Contents.json one level up keeps Xcode happy about the
    # catalog itself existing.
    catalog = out_dir.parent / "Contents.json"
    catalog.write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )

    if preview_path is not None:
        preview_path.parent.mkdir(parents=True, exist_ok=True)
        rounded_preview(master).save(preview_path)

    print(f"wrote {len(IPHONE_SIZES) + 1} PNGs + Contents.json into {out_dir}")
    print(f"master {BASE}x{BASE}  mode={master.mode}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
