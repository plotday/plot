#!/usr/bin/env bash
# Capture one screenshot scene from an iOS Simulator Plot build.
#
# Usage: ios.sh <scene> <mode> <out.png> <dart-arg>...
#
# Boots an "iPhone 16 Pro Max" simulator (the App Store 6.9" device), pins its
# status bar to the 8:32 marketing clock with full signal/battery, launches the
# app via `flutter run -d <udid>` with the given dart entrypoint args (including
# --scene=<id>), waits for the in-app `SCENE_READY:<scene>` marker, then grabs a
# native-resolution screenshot with `simctl io screenshot`.
#
# Prereq: `apps/plot/.env.development` + `app.env` must exist (the iOS build
# bundles them). app.env's API_ROOT must be a host the simulator can reach
# (a public URL or tunnel — simulator localhost is its own, not the Mac's).
set -euo pipefail

SCENE="$1"; MODE="$2"; OUT="$3"; shift 3
DART_ARGS=("$@")
APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
DEVICE="iPhone 16 Pro Max"

# Resolve (or create) the device UDID.
UDID="$(xcrun simctl list devices available | grep -m1 "$DEVICE (" | grep -oE '[0-9A-F-]{36}' || true)"
if [ -z "${UDID:-}" ]; then
  RUNTIME="$(xcrun simctl list runtimes | grep -oE 'com.apple.CoreSimulator.SimRuntime.iOS[^ ]*' | tail -1)"
  UDID="$(xcrun simctl create "$DEVICE" "$DEVICE" "$RUNTIME")"
fi

xcrun simctl boot "$UDID" 2>/dev/null || true
open -a Simulator
xcrun simctl bootstatus "$UDID" -b

apply_status_bar() {
  xcrun simctl status_bar "$UDID" override \
    --time "8:32" --batteryState charged --batteryLevel 100 \
    --cellularBars 4 --wifiBars 3 --dataNetwork wifi --operatorName ' ' 2>/dev/null || true
}
apply_status_bar

# Fresh install per capture. Reinstalling over an existing container leaves
# stale Clerk auth state that intermittently breaks sign-in on the next scene
# (the first scene after a clean install signs in reliably).
xcrun simctl terminate "$UDID" day.plot.app 2>/dev/null || true
xcrun simctl uninstall "$UDID" day.plot.app 2>/dev/null || true

LOG="$(mktemp)"
# iOS does not forward --dart-entrypoint-args to Dart main(args), so translate
# the screenshot config into --dart-define values, which CliArgs reads via
# String.fromEnvironment on every platform. (Changing a define triggers a
# rebuild — unavoidable on mobile.)
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
    *) echo "ios.sh: ignoring unrecognized arg $a" >&2 ;;
  esac
done

( cd "$APP_DIR" && flutter run -d "$UDID" "${RUN_ARGS[@]}" >"$LOG" 2>&1 ) &
RUN_PID=$!
cleanup() { kill "$RUN_PID" 2>/dev/null || true; }
trap cleanup EXIT

# First sim build can take several minutes.
for _ in $(seq 1 300); do
  grep -q "SCENE_READY:$SCENE" "$LOG" && break
  kill -0 "$RUN_PID" 2>/dev/null || { echo "flutter run exited early" >&2; tail -30 "$LOG" >&2; exit 1; }
  sleep 2
done
grep -q "SCENE_READY:$SCENE" "$LOG" || { echo "timeout waiting for SCENE_READY:$SCENE" >&2; tail -30 "$LOG" >&2; exit 1; }

apply_status_bar       # re-assert in case app launch reset it
sleep 3                # let slow-loading destinations + the final frame paint
mkdir -p "$(dirname "$OUT")"
xcrun simctl io "$UDID" screenshot "$OUT"
echo "Saved $OUT (device $UDID)"
