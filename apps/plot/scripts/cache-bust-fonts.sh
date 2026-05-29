#!/usr/bin/env bash
#
# Cache-busts web font assets by appending ?v=$FONT_CACHE_VERSION to every
# font URL in build/web/assets/FontManifest.json after `flutter build web`.
#
# WHY THIS EXISTS
# ---------------
# Flutter web release builds tree-shake icon fonts (e.g. FontAwesomeLight)
# down to only the codepoints actually used in the app. The output filename
# is stable (e.g. Font-Awesome-7-Pro-Light-300.otf), but its CONTENTS change
# whenever the set of icons referenced in the app changes.
#
# Browsers cache the font by URL, not by content, so a user who loaded the
# app before a new icon was added will keep serving the old font from disk
# cache (cache-control max-age) — the new glyph then renders as a "tofu"
# missing-glyph box. Cache-busting via a query string forces browsers to
# fetch a fresh copy.
#
# WHEN TO BUMP FONT_CACHE_VERSION
# -------------------------------
# Bump the integer below by 1 whenever ANY of the following changes:
#   1. You add or remove a Font Awesome icon (anywhere — most commonly in
#      apps/plot/lib/widget/icon.dart, but also any direct
#      FontAwesomeIcons.* reference in the codebase). Adding/removing an
#      icon changes which codepoints survive tree-shaking, so the served
#      font's bytes change.
#   2. You add, change, or replace a font file declared in pubspec.yaml
#      (FontAwesome, Figtree, Inter, etc.).
#   3. You upgrade font_awesome_flutter or any other font-providing
#      dependency.
#
# If unsure, bump it. The cost of an unnecessary bump is one extra font
# refetch per user (~40-1500 KB depending on font); the cost of forgetting
# to bump is broken icons until each user's browser cache expires.
#
# After bumping, commit, then `pnpm build:web` and redeploy.

set -euo pipefail

# >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
# >>>  BUMP THIS WHEN ICONS OR FONT FILES CHANGE (see header above)   <<<
FONT_CACHE_VERSION=11
# >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/build/web/assets/FontManifest.json"

if [[ ! -f "$MANIFEST" ]]; then
  echo "cache-bust-fonts: $MANIFEST not found." >&2
  echo "Run 'flutter build web' before this script." >&2
  exit 1
fi

python3 - "$MANIFEST" "$FONT_CACHE_VERSION" <<'PY'
import json, sys

path, version = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)

count = 0
for family in data:
    for font in family.get("fonts", []):
        asset = font.get("asset", "")
        if not asset:
            continue
        # Strip any existing query string so re-running with a new version
        # replaces (rather than appends) the cache-busting parameter.
        base = asset.split("?", 1)[0]
        font["asset"] = f"{base}?v={version}"
        count += 1

with open(path, "w") as f:
    json.dump(data, f)

print(f"cache-bust-fonts: stamped {count} font URLs with v={version}")
PY
