#!/usr/bin/env bash
# Capture one screenshot scene from an iPad Simulator Plot build (landscape
# multi-panel). Usage: ipad.sh <scene> <mode> <out.png> <dart-arg>...
#
# Mirrors ios.sh but targets the 13" iPad and rotates the simulator to
# landscape (the store-listing spec's iPad layout). Same --dart-define config
# translation as ios.sh (iOS doesn't forward --dart-entrypoint-args to Dart).
#
# Prereq: apps/plot/.env.development + app.env + ios/Runner/GoogleService-Info.plist.
set -euo pipefail

SCENE="$1"; MODE="$2"; OUT="$3"; shift 3
DART_ARGS=("$@")
APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
DEVICE="iPad Pro 13-inch (M4)"

UDID="$(xcrun simctl list devices available | grep -m1 "$DEVICE (" | grep -oE '[0-9A-F-]{36}' || true)"
[ -n "${UDID:-}" ] || { echo "no available $DEVICE sim" >&2; exit 1; }

# Erase first so orientation starts at a known portrait baseline — Cmd+Right
# rotations otherwise ACCUMULATE across runs, making landscape non-deterministic.
# (Also gives the clean fresh-install Clerk state.)
xcrun simctl shutdown "$UDID" 2>/dev/null || true
xcrun simctl erase "$UDID" 2>/dev/null || true
xcrun simctl boot "$UDID" 2>/dev/null || true
open -a Simulator
xcrun simctl bootstatus "$UDID" -b

# Rotate the simulator to landscape before launch (Cmd+Right = clockwise). The
# app launches landscape; simctl still captures the portrait-native framebuffer,
# so the image is rotated back to upright landscape with sips after capture.
rotate_landscape() {
  osascript -e 'tell application "Simulator" to activate' >/dev/null 2>&1 || true
  sleep 1
  osascript -e 'tell application "System Events" to key code 124 using command down' >/dev/null 2>&1 || true
  sleep 2
}
rotate_landscape

apply_status_bar() {
  xcrun simctl status_bar "$UDID" override \
    --time "8:32" --batteryState charged --batteryLevel 100 \
    --cellularBars 4 --wifiBars 3 --dataNetwork wifi --operatorName ' ' 2>/dev/null || true
}
apply_status_bar

# Fresh install per capture (avoids stale Clerk auth — see ios.sh).
xcrun simctl terminate "$UDID" day.plot.app 2>/dev/null || true
xcrun simctl uninstall "$UDID" day.plot.app 2>/dev/null || true

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
    *) echo "ipad.sh: ignoring unrecognized arg $a" >&2 ;;
  esac
done

( cd "$APP_DIR" && flutter run -d "$UDID" "${RUN_ARGS[@]}" >"$LOG" 2>&1 ) &
RUN_PID=$!
trap 'kill "$RUN_PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 300); do
  grep -q "SCENE_READY:$SCENE" "$LOG" && break
  kill -0 "$RUN_PID" 2>/dev/null || { echo "flutter run exited early" >&2; tail -30 "$LOG" >&2; exit 1; }
  sleep 2
done
grep -q "SCENE_READY:$SCENE" "$LOG" || { echo "timeout waiting for SCENE_READY:$SCENE" >&2; tail -30 "$LOG" >&2; exit 1; }

apply_status_bar
sleep 3   # let slow-loading destinations + the final frame paint
mkdir -p "$(dirname "$OUT")"
xcrun simctl io "$UDID" screenshot "$OUT"
# simctl captured the portrait-native framebuffer with landscape content; rotate
# the image to upright landscape. (Direction verified against a clean capture.)
sips -r "${SS_IMG_ROTATE:-90}" "$OUT" >/dev/null 2>&1 || true
echo "Saved $OUT (device $UDID, rotated ${SS_IMG_ROTATE:-90})"
