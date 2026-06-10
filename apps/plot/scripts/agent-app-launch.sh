#!/usr/bin/env bash
# Launch Plot.app in this workspace's isolated agent profile and report the
# DTD URI an agent can hand to dart-mcp via
# mcp__dart-mcp__connect_dart_tooling_daemon.
#
# The agent profile name is derived per-workspace (the repo/worktree directory
# basename), e.g. "agent-plot" for the main checkout and "agent-<worktree>"
# for a worktree, so two agents running concurrently in different worktrees do
# not collide on the same profile, InstanceLock, DB, or /tmp state files.
# Override with $PLOT_AGENT_PROFILE if you need a specific name.
#
# Why this script exists:
#   `flutter run -d macos --machine --print-dtd` is the only flutter_tools
#   path that (a) forwards CLI args to the Dart entrypoint (so the
#   --profile=<agent-profile> arg reaches CliArgs.init) and (b) hands back a
#   DTD URI. It is otherwise well-behaved, but its VM-service discovery on
#   macOS goes through mDNS, which is intermittently slow enough to time out
#   before the agent app publishes its observatory. When that happens the
#   daemon emits app.stop with no app.dtd, then the daemon process dies on its
#   own — leaving the spawned Plot.app alive and unattached. From there the
#   next launch collides on the InstanceLock and the agent is stuck.
#
#   This script wraps the launch with: bootstrap, run, wait for app.dtd,
#   on failure clean up and retry, repeat up to N times.
#
# Outputs (paths include the agent profile so concurrent workspaces differ):
#   /tmp/plot-<agent-profile>-run.log   Full flutter run --machine output.
#   /tmp/plot-<agent-profile>-run.pid   PID of the flutter run daemon (alive on success).
#   /tmp/plot-<agent-profile>-dtd.uri   DTD URI on success — feed this to dart-mcp.
#
# Exit codes:
#   0  app.dtd received; DTD URI written to the -dtd.uri file (printed on success).
#   1  all attempts failed; see the -run.log file (printed on failure).
#
# Usage:
#   bash apps/plot/scripts/agent-app-launch.sh [source-profile]

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
APP_DIR="$REPO_ROOT/apps/plot"
BOOTSTRAP="$APP_DIR/scripts/agent-app-bootstrap.sh"

# Per-workspace agent profile. Must match the derivation in the bootstrap
# script; pass it through explicitly so both halves agree even if the
# defaulting logic ever diverges.
sanitize_token() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' \
    | sed -E 's/-+/-/g; s/^-//; s/-$//'
}
AGENT_PROFILE="${PLOT_AGENT_PROFILE:-agent-$(sanitize_token "$(basename "$REPO_ROOT")")}"

LOG=/tmp/plot-$AGENT_PROFILE-run.log
PID_FILE=/tmp/plot-$AGENT_PROFILE-run.pid
DTD_FILE=/tmp/plot-$AGENT_PROFILE-dtd.uri

MAX_ATTEMPTS=${PLOT_AGENT_LAUNCH_RETRIES:-3}
# 120s is enough for a cold incremental build on this repo plus mDNS
# discovery. The first build from a fresh checkout can need 5+ minutes; in
# that case raise via PLOT_AGENT_LAUNCH_TIMEOUT.
TIMEOUT_SECS=${PLOT_AGENT_LAUNCH_TIMEOUT:-120}

rm -f "$DTD_FILE"

ORPHAN_RE="(flutter_tools.*--profile=$AGENT_PROFILE|Plot\.app.*--profile=$AGENT_PROFILE)"

kill_orphans() {
  local self=$$
  local orphans
  orphans=$(pgrep -f "$ORPHAN_RE" 2>/dev/null \
    | grep -v "^$self\$" || true)
  if [[ -n "$orphans" ]]; then
    # shellcheck disable=SC2086
    kill $orphans 2>/dev/null || true
    sleep 1
    orphans=$(pgrep -f "$ORPHAN_RE" 2>/dev/null \
      | grep -v "^$self\$" || true)
    if [[ -n "$orphans" ]]; then
      # shellcheck disable=SC2086
      kill -9 $orphans 2>/dev/null || true
      sleep 1
    fi
  fi
}

extract_dtd_uri() {
  # The DTD URI lives in the params of the app.dtd event:
  #   [{"event":"app.dtd","params":{"appId":"...","uri":"ws://..."}}]
  grep -oE '"event":"app\.dtd"[^}]*"uri":"[^"]+"' "$LOG" 2>/dev/null \
    | tail -1 \
    | sed -E 's/.*"uri":"([^"]+)".*/\1/'
}

attempt=0
while (( attempt < MAX_ATTEMPTS )); do
  attempt=$((attempt + 1))
  echo "[launch attempt $attempt/$MAX_ATTEMPTS] bootstrapping agent profile $AGENT_PROFILE..."
  if ! bash "$BOOTSTRAP" "${1:-dev}" "$AGENT_PROFILE"; then
    echo "bootstrap failed; aborting." >&2
    exit 1
  fi

  echo "[launch attempt $attempt/$MAX_ATTEMPTS] starting flutter run --machine --print-dtd..."
  : > "$LOG"
  (
    cd "$APP_DIR"
    # nohup detaches from this script's stdout so the daemon survives if we
    # exit (e.g. parent shell SIGHUPs). We do still own it via $PID_FILE.
    # --enable-driver-extension registers the flutter_driver VM service
    # extension so dart-mcp's flutter_driver tool can drive the app. The
    # call is debug-only (gated by kDebugMode in main.dart) and a no-op
    # without this flag, so it is safe to pass unconditionally for the
    # agent profile.
    nohup flutter run -d macos \
      -a --profile="$AGENT_PROFILE" \
      -a --enable-driver-extension \
      --print-dtd --machine \
      > "$LOG" 2>&1 &
    echo $! > "$PID_FILE"
  )
  daemon_pid=$(cat "$PID_FILE")

  # Poll the log for one of three terminal events:
  #   app.dtd       — success, we have the URI
  #   app.stop      — daemon gave up before discovery; retry
  #   daemon death  — daemon crashed; retry
  deadline=$(( $(date +%s) + TIMEOUT_SECS ))
  outcome=
  while :; do
    if grep -q '"event":"app.dtd"' "$LOG" 2>/dev/null; then
      outcome=dtd
      break
    fi
    if grep -q '"event":"app.stop"' "$LOG" 2>/dev/null; then
      outcome=stop
      break
    fi
    if ! kill -0 "$daemon_pid" 2>/dev/null; then
      outcome=died
      break
    fi
    if (( $(date +%s) >= deadline )); then
      outcome=timeout
      break
    fi
    sleep 2
  done

  case "$outcome" in
    dtd)
      uri=$(extract_dtd_uri)
      if [[ -z "$uri" ]]; then
        echo "saw app.dtd event but could not parse URI from log" >&2
        outcome=parse_fail
      else
        echo "$uri" > "$DTD_FILE"
        echo "[launch attempt $attempt/$MAX_ATTEMPTS] OK — DTD URI: $uri"
        echo "  profile:    $AGENT_PROFILE"
        echo "  daemon pid: $daemon_pid (kept alive; kill -INT to stop)"
        echo "  pid file:   $PID_FILE"
        echo "  log:        $LOG"
        echo "  dtd uri:    $DTD_FILE"
        exit 0
      fi
      ;;
  esac

  # Anything other than success — clean up and retry.
  echo "[launch attempt $attempt/$MAX_ATTEMPTS] failed: $outcome" >&2
  echo "  last 5 events from log:" >&2
  grep -E '"event":"' "$LOG" | tail -5 | sed 's/^/    /' >&2 || true

  # Kill the daemon (if alive) AND the spawned Plot.app. Killing the daemon
  # alone leaves the Plot.app holding the InstanceLock, which will block the
  # next attempt.
  kill -INT "$daemon_pid" 2>/dev/null || true
  sleep 2
  kill_orphans
done

echo "all $MAX_ATTEMPTS launch attempts failed; see $LOG" >&2
exit 1
