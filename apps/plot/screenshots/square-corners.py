#!/usr/bin/env python3
"""Square the transparent rounded corners of a macOS window capture in place.

`screencapture -l <window>` of a macOS window bakes in macOS's own rounded
(squircle) corners as transparent pixels. For Windows-emulation captures we want
a clean rectangle so the compose step can apply Windows 11's *circular* corner
radius without the macOS corner showing through as a ghost arc.

Edge-extends each row: leading/trailing transparent pixels are filled with the
nearest opaque pixel. Only corner rows actually have transparency, so this is
fast. Outputs an opaque RGB PNG. Usage: square-corners.py <png> [<png> ...]
"""
import sys
from PIL import Image

OPAQUE = 250  # alpha threshold


def square(path: str) -> None:
    im = Image.open(path).convert("RGBA")
    w, h = im.size
    px = im.load()
    for y in range(h):
        x = 0
        while x < w and px[x, y][3] < OPAQUE:
            x += 1
        if 0 < x < w:
            c = px[x, y]
            for xx in range(x):
                px[xx, y] = c
        x = w - 1
        while x >= 0 and px[x, y][3] < OPAQUE:
            x -= 1
        if -1 < x < w - 1:
            c = px[x, y]
            for xx in range(x + 1, w):
                px[xx, y] = c
    im.convert("RGB").save(path)


if __name__ == "__main__":
    for p in sys.argv[1:]:
        square(p)
        print(f"squared {p}")
