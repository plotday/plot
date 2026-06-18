#!/usr/bin/env bash
# Capture one screenshot scene from an Android emulator Plot build.
# Usage: android.sh <scene> <mode> <out.png> <dart-arg>...
#
# Env overrides:
#   SS_AVD        AVD name           (default Galaxy_S25 — phone)
#   SS_PORT       emulator port      (default 5554)
#   SS_LANDSCAPE  "1" → landscape    (default portrait; set for the tablet)
#
# Android, like iOS, does not forward --dart-entrypoint-args to Dart main(args),
# so the screenshot config is passed via --dart-define (read by CliArgs through
# String.fromEnvironment). Status bar is pinned to 8:32 via SystemUI demo mode;
# capture is `adb exec-out screencap`. Fresh install per scene (clean Clerk
# state). Prereq: android/app/google-services.json + local.properties.
set -euo pipefail

SCENE="$1"; MODE="$2"; OUT="$3"; shift 3
DART_ARGS=("$@")
APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
AVD="${SS_AVD:-Galaxy_S25}"
PORT="${SS_PORT:-5554}"
SERIAL="emulator-$PORT"
ADB="$HOME/Library/Android/sdk/platform-tools/adb"
EMU="${ANDROID_HOME:-$HOME/Library/Android/sdk}/emulator/emulator"

# Boot the emulator if it isn't already online.
if [ "$("$ADB" -s "$SERIAL" get-state 2>/dev/null)" != "device" ]; then
  # Override the AVD's configured RAM: the Plot debug APK is ~150MB, and a
  # streamed install on a 2GB AVD (Galaxy_S25's default) OOM-kills the
  # emulator's system_server mid-install ("Failure calling service package:
  # Broken pipe"). Give it enough headroom. Tunable via SS_EMU_RAM.
  # SS_EMU_EXTRA passes extra emulator flags (e.g. -no-window for a leaner
  # headless capture; screencap reads the framebuffer, so no window is needed).
  nohup "$EMU" -avd "$AVD" -port "$PORT" -no-snapshot-save -no-boot-anim \
    -memory "${SS_EMU_RAM:-6144}" ${SS_EMU_EXTRA:-} >/dev/null 2>&1 &
  "$ADB" -s "$SERIAL" wait-for-device
  until [ "$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do
    sleep 2
  done
fi

# `sys.boot_completed` fires while the Google-Play system image is still bringing
# up GMS/Play services, during which the package manager is unresponsive and a
# `flutter run` install silently stalls (no "Installing" line, then SCENE_READY
# times out). Wait until `pm` actually answers, then a short extra settle, so the
# install proceeds against a ready device. Bounded (~3 min) so a wedged emulator
# still fails fast rather than hanging.
for _ in $(seq 1 60); do
  timeout 8 "$ADB" -s "$SERIAL" shell pm list packages >/dev/null 2>&1 && break
  sleep 3
done
sleep 5

# Suppress ANR / "isn't responding" dialogs so they can't overlay the capture
# (the Tab emulator ANRs under host load; the dialog otherwise survives onto the
# screenshot). Harmless on lighter devices.
"$ADB" -s "$SERIAL" shell settings put global hide_error_dialogs 1 >/dev/null 2>&1 || true

# Force a target orientation and VERIFY it by the captured framebuffer's aspect.
# user_rotation index → orientation is device-dependent: a phone's natural
# orientation is portrait (rot 0), but a tablet may report landscape at a
# different index, and the Flutter app can revert to the emulator's sensor
# default (portrait) on cold start despite a pre-launch rotation. So we try
# rotation candidates and confirm the real screencap matches what we want,
# rather than trusting a hardcoded index. `want` is "land" or "port".
ensure_orientation() {
  local want="$1" cands rot dim w h
  "$ADB" -s "$SERIAL" shell settings put system accelerometer_rotation 0 >/dev/null 2>&1 || true
  [ "$want" = "land" ] && cands="1 3 0 2" || cands="0 2 1 3"
  for rot in $cands; do
    "$ADB" -s "$SERIAL" shell settings put system user_rotation "$rot" >/dev/null 2>&1 || true
    sleep 3
    dim=$("$ADB" -s "$SERIAL" exec-out screencap -p | python3 -c "import sys,struct;d=sys.stdin.buffer.read();w,h=struct.unpack('>II',d[16:24]);print(w,h)" 2>/dev/null) || continue
    w=${dim% *}; h=${dim#* }
    [ -z "$w" ] || [ -z "$h" ] && continue
    if { [ "$want" = "land" ] && [ "$w" -gt "$h" ]; } || { [ "$want" = "port" ] && [ "$h" -gt "$w" ]; }; then
      echo "android.sh: orientation=$want via user_rotation=$rot (${w}x${h})" >&2
      return 0
    fi
  done
  echo "android.sh: WARN could not achieve $want orientation" >&2
  return 1
}

# Orientation: portrait (0) or landscape (1). Set a best-guess before launch so
# the app starts close to the target; re-verified after SCENE_READY below.
"$ADB" -s "$SERIAL" shell settings put system accelerometer_rotation 0 >/dev/null 2>&1 || true
"$ADB" -s "$SERIAL" shell settings put system user_rotation "$([ "${SS_LANDSCAPE:-}" = "1" ] && echo 1 || echo 0)" >/dev/null 2>&1 || true

# SystemUI demo mode: 8:32 clock, full signal/wifi/battery, clean notifications.
demo() { "$ADB" -s "$SERIAL" shell am broadcast -a com.android.systemui.demo "$@" >/dev/null 2>&1 || true; }
"$ADB" -s "$SERIAL" shell settings put global sysui_demo_allowed 1 >/dev/null 2>&1 || true
demo -e command enter
demo -e command clock -e hhmm 0832
demo -e command battery -e level 100 -e plugged false
demo -e command network -e wifi show -e level 4
demo -e command network -e mobile show -e level 4 -e datatype none
demo -e command notifications -e visible false

"$ADB" -s "$SERIAL" uninstall day.plot.app >/dev/null 2>&1 || true

LOG="$(mktemp)"
RUN_ARGS=()
for a in "${DART_ARGS[@]}"; do
  case "$a" in
    --user=*)        RUN_ARGS+=(--dart-define=SS_USER="${a#--user=}") ;;
    --password=*)    RUN_ARGS+=(--dart-define=SS_PASSWORD="${a#--password=}") ;;
    --frozen-time=*) RUN_ARGS+=(--dart-define=SS_FROZEN_TIME="${a#--frozen-time=}") ;;
    --light-mode)    RUN_ARGS+=(--dart-define=SS_MODE=light) ;;
    --dark-mode)     RUN_ARGS+=(--dart-define=SS_MODE=dark) ;;
    --profile=*)     RUN_ARGS+=(--dart-define=SS_PROFILE="${a#--profile=}") ;;
    --scene=*)       RUN_ARGS+=(--dart-define=SS_SCENE="${a#--scene=}") ;;
    *) echo "android.sh: ignoring unrecognized arg $a" >&2 ;;
  esac
done

( cd "$APP_DIR" && flutter run -d "$SERIAL" "${RUN_ARGS[@]}" >"$LOG" 2>&1 ) &
RUN_PID=$!
trap 'kill "$RUN_PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 600); do   # Android cold/native (Rust) builds are slow
  grep -q "SCENE_READY:$SCENE" "$LOG" && break
  kill -0 "$RUN_PID" 2>/dev/null || { echo "flutter run exited early" >&2; tail -30 "$LOG" >&2; exit 1; }
  sleep 2
done
grep -q "SCENE_READY:$SCENE" "$LOG" || { echo "timeout waiting for SCENE_READY:$SCENE" >&2; tail -30 "$LOG" >&2; exit 1; }

# Now that the app window is up, force + verify the orientation (rotating the
# live activity, which handles configChanges=orientation without recreation).
ensure_orientation "$([ "${SS_LANDSCAPE:-}" = "1" ] && echo land || echo port)" || true

demo -e command clock -e hhmm 0832   # re-assert (a rotation can reset the bar)
sleep 8   # Android emulator + first-view note sync is slow; let the thread body load
mkdir -p "$(dirname "$OUT")"
"$ADB" -s "$SERIAL" exec-out screencap -p > "$OUT"

# Sanity-check the captured aspect matches the requested orientation.
DIM=$(python3 -c "import struct,sys;d=open('$OUT','rb').read();w,h=struct.unpack('>II',d[16:24]);print(f'{w}x{h}',('land' if w>h else 'port'))" 2>/dev/null || echo "?")
echo "Saved $OUT ($SERIAL) ${DIM}"
