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
PROFILE="$(printf '%s\n' "${DART_ARGS[@]}" | sed -n 's/^--profile=//p' | head -1)"
APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WIN_W=1440
WIN_H=900

LOG="$(mktemp)"

# SS_PREBUILT=1 launches the already-built Debug binary directly with the scene
# args (which the macOS runner forwards to Dart main → CliArgs) instead of
# `flutter run`. This skips the per-scene Dart recompile — essential when another
# agent is concurrently editing app source in the same checkout (a transiently
# broken tree fails `flutter run`'s rebuild). The scene id / --dark-mode /
# --emulate-windows are all runtime args, so one Debug build captures every
# macOS and Windows scene. Build it once (e.g. `flutter build macos --debug`)
# before running with SS_PREBUILT=1.
PREBUILT_BIN="$APP_DIR/build/macos/Build/Products/Debug/Plot.app/Contents/MacOS/Plot"
if [ "${SS_PREBUILT:-}" = "1" ]; then
  [ -x "$PREBUILT_BIN" ] || { echo "SS_PREBUILT=1 but no prebuilt binary at $PREBUILT_BIN" >&2; exit 1; }
  ( "$PREBUILT_BIN" "${DART_ARGS[@]}" >"$LOG" 2>&1 ) &
else
  RUN_ARGS=()
  for a in "${DART_ARGS[@]}"; do RUN_ARGS+=(--dart-entrypoint-args="$a"); done
  ( cd "$APP_DIR" && flutter run -d macos "${RUN_ARGS[@]}" >"$LOG" 2>&1 ) &
fi
RUN_PID=$!

cleanup() { kill "$RUN_PID" 2>/dev/null || true; [ -n "$PROFILE" ] && pkill -f "profile=$PROFILE" 2>/dev/null || true; }
trap cleanup EXIT

# Wait for the scene to compose (first build can take minutes).
for _ in $(seq 1 300); do
  grep -q "SCENE_READY:$SCENE" "$LOG" && break
  kill -0 "$RUN_PID" 2>/dev/null || { echo "flutter run exited early" >&2; tail -30 "$LOG" >&2; exit 1; }
  sleep 2
done
grep -q "SCENE_READY:$SCENE" "$LOG" || { echo "timeout waiting for SCENE_READY:$SCENE" >&2; tail -30 "$LOG" >&2; exit 1; }
sleep 3  # let slow-loading destinations + the final frame paint

# Resolve this instance's window id. We can't match on an exact 1440x900 size:
# on a scaled multi-display setup the scene window reports different global-
# coordinate bounds (e.g. 1296x811 when placed on a scaled Retina panel), and a
# developer's own Plot instance may also be open. Instead, find the macOS app
# process this run launched — it carries this run's `profile=$PROFILE` in its
# argv — and pick the largest layer-0 window owned by that PID (the main scene
# window, not the menu-bar popover). Falls back to the largest Plot window.
APP_PIDS="$(pgrep -f "Plot.app/Contents/MacOS/Plot.*profile=${PROFILE}" | tr '\n' ' ')"
WIN_ID="$(python3 - "$APP_PIDS" <<'PY'
import sys, Quartz
pids = {int(x) for x in sys.argv[1].split()} if sys.argv[1].strip() else set()
wins = Quartz.CGWindowListCopyWindowInfo(
    Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
    Quartz.kCGNullWindowID)
plot = [w for w in wins
        if w.get('kCGWindowOwnerName') == 'Plot' and w.get('kCGWindowLayer') == 0]
def area(w):
    b = w['kCGWindowBounds']; return int(b['Width']) * int(b['Height'])
owned = [w for w in plot if int(w.get('kCGWindowOwnerPID', -1)) in pids]
cands = owned or plot          # prefer our PID; else any Plot window
cands.sort(key=area, reverse=True)
# stderr breadcrumb for diagnosing a wrong pick (Screen Recording etc.).
for w in cands:
    b = w['kCGWindowBounds']
    sys.stderr.write(f"  cand pid={w.get('kCGWindowOwnerPID')} "
                     f"{int(b['Width'])}x{int(b['Height'])} num={w['kCGWindowNumber']}\n")
print(cands[0]['kCGWindowNumber'] if cands else '')
PY
)"
[ -n "$WIN_ID" ] || { echo "no Plot window found (pids: ${APP_PIDS:-none})" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
screencapture -x -o -l"$WIN_ID" "$OUT"

# Windows-emulation captures: square the macOS window's transparent squircle
# corners so the compose step can apply Windows 11's circular corner radius
# cleanly (no macOS corner ghosting through). macOS App Store captures keep
# their real macOS corners, so this runs only for --emulate-windows.
if printf '%s\n' "${DART_ARGS[@]}" | grep -q -- '--emulate-windows'; then
  python3 "$(dirname "$0")/../square-corners.py" "$OUT" || \
    echo "warning: square-corners.py failed for $OUT" >&2
fi
echo "Saved $OUT (window $WIN_ID)"
