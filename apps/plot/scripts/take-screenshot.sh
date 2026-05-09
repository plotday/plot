#!/usr/bin/env bash
# Capture a screenshot from one of the running screenshot emulators.
#
# Usage:
#   scripts/take-screenshot.sh s25 home-light
#   scripts/take-screenshot.sh tab agenda-dark
#
# Output: apps/plot/screenshots/{galaxy-s25,galaxy-tab-s8-ultra}/<name>.png

set -euo pipefail

ADB="$HOME/Library/Android/sdk/platform-tools/adb"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

case "${1:-}" in
  s25|S25|galaxy-s25) SERIAL=emulator-5554 ; OUT_DIR="$ROOT/screenshots/galaxy-s25" ;;
  tab|TAB|tablet|galaxy-tab|galaxy-tab-s8-ultra) SERIAL=emulator-5556 ; OUT_DIR="$ROOT/screenshots/galaxy-tab-s8-ultra" ;;
  *) echo "Usage: $0 <s25|tab> <name>" >&2 ; exit 1 ;;
esac

NAME="${2:-screenshot-$(date +%Y%m%d-%H%M%S)}"
NAME="${NAME%.png}"
OUT="$OUT_DIR/$NAME.png"

mkdir -p "$OUT_DIR"
"$ADB" -s "$SERIAL" exec-out screencap -p > "$OUT"
echo "Saved: $OUT ($(wc -c < "$OUT") bytes)"
