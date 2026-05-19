#!/usr/bin/env bash
# Launch Plot.app in the isolated "agent" profile and report the DTD URI an
# agent can hand to dart-mcp via mcp__dart-mcp__connect_dart_tooling_daemon.
#
# Why this script exists:
#   `flutter run -d macos --machine --print-dtd` is the only flutter_tools
#   path that (a) forwards CLI args to the Dart entrypoint (so --profile=agent
#   reaches CliArgs.init) and (b) hands back a DTD URI. It is otherwise
#   well-behaved, but its VM-service discovery on macOS goes through mDNS,
#   which is intermittently slow enough to time out before the agent app
#   publishes its observatory. When that happens the daemon emits app.stop
#   with no app.dtd, then the daemon process dies on its own — leaving the
#   spawned Plot.app alive and unattached. From there the next launch
#   collides on the InstanceLock and the agent is stuck.
#
#   This script wraps the launch with: bootstrap, run, wait for app.dtd,
#   on failure clean up and retry, repeat up to N times.
#
# Outputs:
#   /tmp/plot-agent-run.log       Full flutter run --machine output (last attempt).
#   /tmp/plot-agent-run.pid       PID of the flutter run daemon (still alive on success).
#   /tmp/plot-agent-dtd.uri       DTD URI on success — feed this to dart-mcp.
#
# Exit codes:
#   0  app.dtd received; DTD URI written to /tmp/plot-agent-dtd.uri.
#   1  all attempts failed; see /tmp/plot-agent-run.log for the last attempt.
#
# Usage:
#   bash apps/plot/scripts/agent-app-launch.sh [source-profile]

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
APP_DIR="$REPO_ROOT/apps/plot"
BOOTSTRAP="$APP_DIR/scripts/agent-app-bootstrap.sh"
LOG=/tmp/plot-agent-run.log
PID_FILE=/tmp/plot-agent-run.pid
DTD_FILE=/tmp/plot-agent-dtd.uri

MAX_ATTEMPTS=${PLOT_AGENT_LAUNCH_RETRIES:-3}
# 120s is enough for a cold incremental build on this repo plus mDNS
# discovery. The first build from a fresh checkout can need 5+ minutes; in
# that case raise via PLOT_AGENT_LAUNCH_TIMEOUT.
TIMEOUT_SECS=${PLOT_AGENT_LAUNCH_TIMEOUT:-120}

rm -f "$DTD_FILE"

kill_orphans() {
  local self=$$
  local orphans
  orphans=$(pgrep -f '(flutter_tools.*--profile=agent|Plot\.app.*--profile=agent)' 2>/dev/null \
    | grep -v "^$self\$" || true)
  if [[ -n "$orphans" ]]; then
    # shellcheck disable=SC2086
    kill $orphans 2>/dev/null || true
    sleep 1
    orphans=$(pgrep -f '(flutter_tools.*--profile=agent|Plot\.app.*--profile=agent)' 2>/dev/null \
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
  echo "[launch attempt $attempt/$MAX_ATTEMPTS] bootstrapping agent profile..."
  if ! bash "$BOOTSTRAP" "${1:-dev}"; then
    echo "bootstrap failed; aborting." >&2
    exit 1
  fi

  echo "[launch attempt $attempt/$MAX_ATTEMPTS] starting flutter run --machine --print-dtd..."
  : > "$LOG"
  (
    cd "$APP_DIR"
    # nohup detaches from this script's stdout so the daemon survives if we
    # exit (e.g. parent shell SIGHUPs). We do still own it via $PID_FILE.
    nohup flutter run -d macos -a --profile=agent --print-dtd --machine \
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
        echo "  daemon pid: $daemon_pid (kept alive; kill -INT to stop)"
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
