#!/usr/bin/env python3
"""Generate apps/plot/lib/widget/emoji_data.g.dart from the official
Unicode emoji-test.txt for the current Emoji release.

Run when bumping to a new Emoji version. The output is the canonical
source of truth for the reaction picker's grid + search keywords.

Usage:
  python3 apps/plot/scripts/gen_emoji_data.py [emoji-version]

Default version is 15.1; change EMOJI_VERSION to bump.
"""
import os
import re
import sys
import urllib.request
from pathlib import Path

EMOJI_VERSION = "15.1"
SCRIPT_DIR = Path(__file__).resolve().parent
OUT_PATH = SCRIPT_DIR.parent / "lib" / "widget" / "emoji_data.g.dart"

# Category order: most-used first, then alphabetical for the rest.
CATEGORY_ORDER = [
    "Smileys & Emotion",
    "People & Body",
    "Animals & Nature",
    "Food & Drink",
    "Travel & Places",
    "Activities",
    "Objects",
    "Symbols",
    "Flags",
]


def fetch_lines(version: str):
    url = f"https://unicode.org/Public/emoji/{version}/emoji-test.txt"
    with urllib.request.urlopen(url, timeout=30) as r:
        return r.read().decode("utf-8").splitlines()


def parse(lines):
    cur_group = None
    cur_sub = None
    data: dict[str, list[tuple[str, str, list[str]]]] = {}
    for line in lines:
        m = re.match(r"#\s*group:\s*(.+)", line)
        if m:
            cur_group = m.group(1).strip()
            continue
        m = re.match(r"#\s*subgroup:\s*(.+)", line)
        if m:
            cur_sub = m.group(1).strip()
            continue
        if not line or line.startswith("#"):
            continue
        m = re.match(
            r"([0-9A-Fa-f ]+);\s*(\S+)\s*#\s*(\S+)\s+E[\d.]+\s+(.+)", line
        )
        if not m:
            continue
        if m.group(2) != "fully-qualified":
            continue
        emoji = m.group(3)
        name = m.group(4).strip()
        # Skin-tone variants swamp the picker without adding much value.
        if "skin tone" in name:
            continue
        if cur_group and cur_group.lower() == "component":
            continue
        if cur_group is None:
            continue
        kws = sorted(
            set(re.findall(r"[a-zA-Z0-9']+", (name + " " + (cur_sub or "")).lower()))
        )
        data.setdefault(cur_group, []).append((emoji, name, kws))
    return data


def dart_str(s: str) -> str:
    return (
        "'"
        + s.replace("\\", "\\\\").replace("'", "\\'").replace("$", "\\$")
        + "'"
    )


def emit(data: dict[str, list[tuple[str, str, list[str]]]], version: str) -> str:
    ordered = [g for g in CATEGORY_ORDER if g in data] + [
        g for g in data if g not in CATEGORY_ORDER
    ]
    out: list[str] = []
    out.append("// GENERATED FILE — do not edit by hand.")
    out.append(
        f"// Source: https://unicode.org/Public/emoji/{version}/emoji-test.txt"
    )
    out.append("// Regenerate via apps/plot/scripts/gen_emoji_data.py.")
    out.append("//")
    out.append("// Emits three constants used by emoji_picker.dart:")
    out.append("//  - kUnicodeEmojiCategories: ordered category -> list of emoji.")
    out.append("//  - kUnicodeEmojiNames:      emoji -> canonical CLDR name (e.g. 'grinning face').")
    out.append("//  - kUnicodeEmojiLabels:     emoji -> search keywords (CLDR name words).")
    out.append("//")
    out.append("// Skin-tone variants and the \"Component\" group are intentionally")
    out.append("// excluded from the picker — they swamp the grid without adding much.")
    out.append("")
    out.append("const Map<String, List<String>> kUnicodeEmojiCategories = {")
    for g in ordered:
        out.append(f"  {dart_str(g)}: [")
        items = data[g]
        for i in range(0, len(items), 10):
            chunk = items[i : i + 10]
            out.append(
                "    " + ", ".join(dart_str(e[0]) for e in chunk) + ","
            )
        out.append("  ],")
    out.append("};")
    out.append("")
    out.append("const Map<String, String> kUnicodeEmojiNames = {")
    seen_names: set[str] = set()
    for g in ordered:
        for emoji, name, _ in data[g]:
            if emoji in seen_names:
                continue
            seen_names.add(emoji)
            out.append("  " + dart_str(emoji) + ": " + dart_str(name) + ",")
    out.append("};")
    out.append("")
    out.append("const Map<String, List<String>> kUnicodeEmojiLabels = {")
    seen: set[str] = set()
    for g in ordered:
        for emoji, name, kws in data[g]:
            if emoji in seen:
                continue
            seen.add(emoji)
            out.append(
                "  "
                + dart_str(emoji)
                + ": ["
                + ", ".join(dart_str(k) for k in kws)
                + "],"
            )
    out.append("};")
    out.append("")
    return "\n".join(out)


def main() -> int:
    version = sys.argv[1] if len(sys.argv) > 1 else EMOJI_VERSION
    print(f"Fetching emoji-test.txt v{version}…", file=sys.stderr)
    lines = fetch_lines(version)
    data = parse(lines)
    total = sum(len(v) for v in data.values())
    print(
        f"Parsed {total} emoji across {len(data)} groups", file=sys.stderr
    )
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(emit(data, version))
    print(f"Wrote {OUT_PATH.relative_to(SCRIPT_DIR.parent.parent.parent)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
