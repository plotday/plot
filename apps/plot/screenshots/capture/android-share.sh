#!/usr/bin/env bash
# Capture S12 — the Android share sheet with Plot as a target ("Share into Plot
# from any app"). Usage: android-share.sh <out.png>
#
# Unlike the other scenes this is an OS-level flow, not an in-app scene: it
# triggers a SEND (share) intent for a link and screenshots the system chooser
# (which lists Plot because the app registers an ACTION_SEND text filter).
#
# Prereq: Plot must be INSTALLED on the running emulator — run any
# `android.sh <scene> ...` first (it builds + installs). Plot need not be the
# foreground app.
set -euo pipefail

OUT="$1"
PORT="${SS_PORT:-5554}"
SERIAL="emulator-$PORT"
ADB="$HOME/Library/Android/sdk/platform-tools/adb"
LINK="${SS_SHARE_LINK:-https://linear.app/afc-marlow/issue/AFC-128/founding-partner-deck}"

"$ADB" -s "$SERIAL" get-state >/dev/null 2>&1 || { echo "emulator $SERIAL not running" >&2; exit 1; }
"$ADB" -s "$SERIAL" shell pm list packages 2>/dev/null | grep -q day.plot.app \
  || { echo "Plot not installed — run android.sh <scene> first" >&2; exit 1; }

# 8:32 status bar via SystemUI demo mode.
"$ADB" -s "$SERIAL" shell settings put global sysui_demo_allowed 1 >/dev/null 2>&1 || true
demo() { "$ADB" -s "$SERIAL" shell am broadcast -a com.android.systemui.demo "$@" >/dev/null 2>&1 || true; }
demo -e command enter
demo -e command clock -e hhmm 0832
demo -e command battery -e level 100 -e plugged false
demo -e command network -e wifi show -e level 4
demo -e command network -e mobile show -e level 4 -e datatype none
demo -e command notifications -e visible false

# Trigger the share chooser for a link; wait for the (slow emulator) chooser to
# render its items, then capture.
"$ADB" -s "$SERIAL" shell input keyevent KEYCODE_HOME >/dev/null 2>&1; sleep 1
"$ADB" -s "$SERIAL" shell am start -a android.intent.action.SEND -t "text/plain" \
  --es android.intent.extra.TEXT "$LINK" >/dev/null 2>&1
sleep 7
mkdir -p "$(dirname "$OUT")"
"$ADB" -s "$SERIAL" exec-out screencap -p > "$OUT"
echo "Saved $OUT ($SERIAL — share chooser)"
