#!/usr/bin/env bash
# Build the Play Store featured graphic (1024x500 PNG).
#
# Sources (all version-controlled, so this is reproducible from a clean clone):
#   - App screenshot:         ./source-screenshot.png (S7 dark, android-tablet capture)
#   - Brand wordmark:         apps/site/public/assets/plot.svg
#   - Font (Instrument Sans): fetched from google/fonts on demand
#
# Outputs:
#   - ./featureGraphic.svg   (source, version controlled)
#   - ../featureGraphic.png  (1024x500, what Play Console / Fastlane Supply uploads)
#
# IMPORTANT: Fastlane Supply only discovers the feature graphic at the FLAT path
# images/featureGraphic.png — it does NOT look inside an images/featureGraphic/
# subdirectory. So the generated PNG is written one level up (../) while the
# build inputs (this script, the .svg, the source screenshot) stay in this dir,
# which Supply ignores.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../../../../../../.." && pwd)"
SITE_ASSETS="$REPO/apps/site/public/assets"

WORK="${TMPDIR:-/tmp}/plot-feature-graphic"
FONT_DIR="$WORK/fonts"
FONT_FILE="$FONT_DIR/InstrumentSans.ttf"
FONT_URL='https://raw.githubusercontent.com/google/fonts/main/ofl/instrumentsans/InstrumentSans%5Bwdth%2Cwght%5D.ttf'
mkdir -p "$FONT_DIR"

if [ ! -s "$FONT_FILE" ]; then
  echo "fetching Instrument Sans..."
  curl -sSL --fail "$FONT_URL" -o "$FONT_FILE"
fi

# Fontconfig file that adds our font dir and aliases generic families to Instrument Sans
FC_FILE="$WORK/fonts.conf"
cat > "$FC_FILE" <<EOF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <dir>$FONT_DIR</dir>
  <cachedir>$WORK/fontcache</cachedir>
  <alias>
    <family>sans-serif</family>
    <prefer><family>Instrument Sans</family></prefer>
  </alias>
</fontconfig>
EOF

# Crop the screenshot to a tighter framing so it reads at 460px wide
SHOT_SRC="$HERE/source-screenshot.png"
SHOT_TRIM="$WORK/screenshot-trimmed.png"
magick "$SHOT_SRC" -resize 1320x -gravity north -crop 1320x780+0+30 +repage "$SHOT_TRIM"

SHOT_B64=$(base64 -i "$SHOT_TRIM" | tr -d '\n')
LOGO_B64=$(base64 -i "$SITE_ASSETS/plot.svg" | tr -d '\n')

SVG="$HERE/featureGraphic.svg"
# Flat path (parent dir): Supply only finds images/featureGraphic.png, not a subdir.
PNG="$HERE/../featureGraphic.png"

cat > "$SVG" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
     viewBox="0 0 1024 500" width="1024" height="500">
  <defs>
    <!-- Base dark background gradient (matches app dark mode) -->
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0"   stop-color="#04130c"/>
      <stop offset="0.55" stop-color="#0a1f17"/>
      <stop offset="1"   stop-color="#1a0f1a"/>
    </linearGradient>

    <!-- Soft green glow, top-left -->
    <radialGradient id="glowGreen" cx="0.18" cy="0.22" r="0.55">
      <stop offset="0"   stop-color="#01845e" stop-opacity="0.55"/>
      <stop offset="0.5" stop-color="#01845e" stop-opacity="0.18"/>
      <stop offset="1"   stop-color="#01845e" stop-opacity="0"/>
    </radialGradient>

    <!-- Soft mauve glow, bottom-right -->
    <radialGradient id="glowMauve" cx="0.85" cy="0.92" r="0.5">
      <stop offset="0"   stop-color="#946390" stop-opacity="0.45"/>
      <stop offset="0.6" stop-color="#946390" stop-opacity="0.12"/>
      <stop offset="1"   stop-color="#946390" stop-opacity="0"/>
    </radialGradient>

    <!-- Title gradient (brand green -> secondary mauve) -->
    <linearGradient id="titleGrad" x1="0" y1="0" x2="1" y2="0.4">
      <stop offset="0"    stop-color="#7ed7b1"/>
      <stop offset="0.55" stop-color="#bdffe3"/>
      <stop offset="1"    stop-color="#cca4c9"/>
    </linearGradient>

    <!-- Subtle vignette behind screenshot -->
    <radialGradient id="shotGlow" cx="0.5" cy="0.5" r="0.65">
      <stop offset="0"   stop-color="#01845e" stop-opacity="0.55"/>
      <stop offset="0.6" stop-color="#01845e" stop-opacity="0.10"/>
      <stop offset="1"   stop-color="#01845e" stop-opacity="0"/>
    </radialGradient>

    <!-- Drop shadow for screenshot card -->
    <filter id="shotShadow" x="-20%" y="-20%" width="140%" height="160%">
      <feGaussianBlur in="SourceAlpha" stdDeviation="14"/>
      <feOffset dx="0" dy="10" result="off"/>
      <feComponentTransfer><feFuncA type="linear" slope="0.55"/></feComponentTransfer>
      <feMerge>
        <feMergeNode/>
        <feMergeNode in="SourceGraphic"/>
      </feMerge>
    </filter>

    <!-- Rounded clip for screenshot -->
    <clipPath id="shotClip">
      <rect x="0" y="0" width="1320" height="780" rx="36" ry="36"/>
    </clipPath>

    <!-- Pill background -->
    <linearGradient id="pillBg" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#ffffff" stop-opacity="0.10"/>
      <stop offset="1" stop-color="#ffffff" stop-opacity="0.05"/>
    </linearGradient>
  </defs>

  <!-- background layers -->
  <rect width="1024" height="500" fill="url(#bg)"/>
  <rect width="1024" height="500" fill="url(#glowGreen)"/>
  <rect width="1024" height="500" fill="url(#glowMauve)"/>

  <!-- Plot wordmark -->
  <image x="56" y="50" width="118" height="37"
         preserveAspectRatio="xMinYMin meet"
         xlink:href="data:image/svg+xml;base64,$LOGO_B64"/>

  <!-- Headline -->
  <g font-family="Instrument Sans, sans-serif" font-weight="700" letter-spacing="-1.2">
    <text x="56" y="200" font-size="68" fill="url(#titleGrad)">All your work,</text>
    <text x="56" y="272" font-size="68" fill="url(#titleGrad)">ready for action</text>
  </g>

  <!-- Subhead -->
  <g font-family="Instrument Sans, sans-serif" font-weight="400" fill="#e6efe9" opacity="0.86">
    <text x="56" y="332" font-size="22">Team chat, email, notes, and app threads,</text>
    <text x="56" y="362" font-size="22">organized around your priorities.</text>
  </g>

  <!-- "Now on Android" pill -->
  <g transform="translate(56 410)">
    <rect width="206" height="40" rx="20" ry="20" fill="url(#pillBg)" stroke="#7ed7b1" stroke-opacity="0.35"/>
    <circle cx="20" cy="20" r="5" fill="#7ed7b1"/>
    <text x="36" y="26" font-family="Instrument Sans, sans-serif" font-weight="600" font-size="16" fill="#e6efe9">
      Now on Android
    </text>
  </g>

  <!-- Screenshot card (right side) -->
  <g transform="translate(556 76) rotate(-3 230 158)">
    <!-- glow behind -->
    <ellipse cx="230" cy="158" rx="280" ry="180" fill="url(#shotGlow)"/>
    <g filter="url(#shotShadow)">
      <g transform="scale(0.349)" clip-path="url(#shotClip)">
        <image x="0" y="0" width="1320" height="780"
               preserveAspectRatio="xMidYMid slice"
               xlink:href="data:image/png;base64,$SHOT_B64"/>
      </g>
      <!-- thin border to crisp the card edge -->
      <rect x="0" y="0" width="460" height="272" rx="13" ry="13"
            fill="none" stroke="#ffffff" stroke-opacity="0.10"/>
    </g>
  </g>
</svg>
EOF

echo "rendering $PNG..."
FONTCONFIG_FILE="$FC_FILE" rsvg-convert -w 1024 -h 500 "$SVG" -o "$PNG"

# Play accepts 24-bit PNG (no alpha). Re-encode without alpha so we never trip the validator.
magick "$PNG" -background "#04130c" -alpha remove -alpha off -strip "$PNG"

echo "wrote: $PNG"
magick identify "$PNG"
