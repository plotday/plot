#!/usr/bin/env python3
"""Generate dev app icons with an orange badge overlay.

Reads the source icon from assets/plot-512x512.png and produces resized
versions with an orange circle badge in the bottom-right corner. Output
goes to macos/Runner/Assets.xcassets/AppIcon-Dev.appiconset/.

Requirements: Pillow (pip3 install Pillow)
"""

import json
import os
from pathlib import Path

from PIL import Image, ImageDraw

SCRIPT_DIR = Path(__file__).resolve().parent
APP_DIR = SCRIPT_DIR.parent
SOURCE_ICON = APP_DIR / "assets" / "plot-512x512.png"
OUTPUT_DIR = (
    APP_DIR / "macos" / "Runner" / "Assets.xcassets" / "AppIcon-Dev.appiconset"
)

SIZES = [16, 32, 64, 128, 256, 512, 1024]

BADGE_COLOR = (255, 149, 0)  # #FF9500 orange
BORDER_COLOR = (255, 255, 255)  # white


def generate_icon(source: Image.Image, size: int) -> Image.Image:
    icon = source.resize((size, size), Image.LANCZOS)
    draw = ImageDraw.Draw(icon)

    diameter = round(size * 0.22)
    padding = round(size * 0.08)
    border_width = max(1, round(size * 0.01))

    # Bottom-right position
    x = size - padding - diameter
    y = size - padding - diameter

    # White border circle (slightly larger)
    draw.ellipse(
        [x - border_width, y - border_width, x + diameter + border_width, y + diameter + border_width],
        fill=BORDER_COLOR,
    )
    # Orange fill
    draw.ellipse([x, y, x + diameter, y + diameter], fill=BADGE_COLOR)

    return icon


def write_contents_json(output_dir: Path) -> None:
    images = []
    entries = [
        ("16x16", "1x", 16),
        ("16x16", "2x", 32),
        ("32x32", "1x", 32),
        ("32x32", "2x", 64),
        ("128x128", "1x", 128),
        ("128x128", "2x", 256),
        ("256x256", "1x", 256),
        ("256x256", "2x", 512),
        ("512x512", "1x", 512),
        ("512x512", "2x", 1024),
    ]
    for size_str, scale, px in entries:
        images.append(
            {
                "size": size_str,
                "idiom": "mac",
                "filename": f"app_icon_dev_{px}.png",
                "scale": scale,
            }
        )

    contents = {"info": {"version": 1, "author": "xcode"}, "images": images}
    with open(output_dir / "Contents.json", "w") as f:
        json.dump(contents, f, indent=4)
        f.write("\n")


def main() -> None:
    if not SOURCE_ICON.exists():
        raise FileNotFoundError(f"Source icon not found: {SOURCE_ICON}")

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    source = Image.open(SOURCE_ICON).convert("RGBA")

    for size in SIZES:
        icon = generate_icon(source, size)
        out_path = OUTPUT_DIR / f"app_icon_dev_{size}.png"
        icon.save(out_path)
        print(f"  {out_path.name} ({size}x{size})")

    write_contents_json(OUTPUT_DIR)
    print(f"\nDev icons written to {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
