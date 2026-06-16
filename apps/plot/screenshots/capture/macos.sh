#!/usr/bin/env bash
# Capture one screenshot scene from a macOS Plot build.
#
# Usage: macos.sh <scene> <mode> <out.png> <dart-arg>...
#
# Launches the app via `flutter run -d macos` with the given dart entrypoint
# args (which include --scene=<id>), waits for the in-app `SCENE_READY:<scene>`
# marker, then captures the app window by its CGWindowID.
#
# Why window-ID capture (not `screencapture -R <region>`): on a multi-display
# setup the global-coordinate region capture grabs the wrong area (terminal
# bleed-through). `screencapture -l <id>` grabs the exact window bitmap
# regardless of position, overlap, or which display it is on.
#
# The screenshot scene pins the window to 1440x900 (window_manager), so we
# select the 1440x900 Plot window — this also disambiguates from a developer's
# own running Plot instance (a different size).
#
# Prereq: `apps/plot/.env.development` + `app.env` must exist (the macOS build
# bundles them). In a fresh worktree run `pnpm cp-env <main-repo>` first.
set -euo pipefail

SCENE="$1"; MODE="$2"; OUT="$3"; shift 3
DART_ARGS=("$@")
APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WIN_W=1440
WIN_H=900

LOG="$(mktemp)"
RUN_ARGS=()
for a in "${DART_ARGS[@]}"; do RUN_ARGS+=(--dart-entrypoint-args="$a"); done

( cd "$APP_DIR" && flutter run -d macos "${RUN_ARGS[@]}" >"$LOG" 2>&1 ) &
RUN_PID=$!

cleanup() { kill "$RUN_PID" 2>/dev/null || true; pkill -f "profile=screenshots-macos" 2>/dev/null || true; }
trap cleanup EXIT

# Wait for the scene to compose (first build can take minutes).
for _ in $(seq 1 300); do
  grep -q "SCENE_READY:$SCENE" "$LOG" && break
  kill -0 "$RUN_PID" 2>/dev/null || { echo "flutter run exited early" >&2; tail -30 "$LOG" >&2; exit 1; }
  sleep 2
done
grep -q "SCENE_READY:$SCENE" "$LOG" || { echo "timeout waiting for SCENE_READY:$SCENE" >&2; tail -30 "$LOG" >&2; exit 1; }
sleep 3  # let slow-loading destinations + the final frame paint

# Resolve this instance's window id (the 1440x900 one the scene pinned).
WIN_ID="$(python3 - "$WIN_W" "$WIN_H" <<'PY'
import sys, Quartz
w_want, h_want = int(sys.argv[1]), int(sys.argv[2])
wins = Quartz.CGWindowListCopyWindowInfo(
    Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
    Quartz.kCGNullWindowID)
match = []
for w in wins:
    if w.get('kCGWindowOwnerName') == 'Plot' and w.get('kCGWindowLayer') == 0:
        b = w['kCGWindowBounds']
        if int(b['Width']) == w_want and int(b['Height']) == h_want:
            match.append(int(w['kCGWindowNumber']))
print(match[0] if match else '')
PY
)"
[ -n "$WIN_ID" ] || { echo "could not find a ${WIN_W}x${WIN_H} Plot window" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
screencapture -x -o -l"$WIN_ID" "$OUT"
echo "Saved $OUT (window $WIN_ID)"
