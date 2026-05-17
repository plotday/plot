#!/usr/bin/env bash
# Bootstrap an isolated "agent" profile so a dart-mcp-launched Plot.app does
# not collide with the developer's daily dev/release instances.
#
# What it does:
#   1. Verifies a signed-in source profile exists (default: dev). Without a
#      cached Clerk session, the agent instance lands on the sign-in page.
#   2. Copies that profile's Clerk session into clerk_profile_agent (only if
#      missing — repeat invocations are no-ops).
#   3. Releases any stale agent lock from a crashed previous run.
#
# Re-run safely. Idempotent.
#
# Usage:
#   bash scripts/agent-app-bootstrap.sh [source-profile]
#
# Default source-profile is "dev". Pass "default" if you only sign in via the
# release app, or any other profile name that has a current Clerk session.

set -euo pipefail

SOURCE_PROFILE="${1:-dev}"
APP_SUPPORT="$HOME/Library/Containers/day.plot.app/Data/Library/Application Support/day.plot.app"
SOURCE_CLERK="$APP_SUPPORT/clerk_profile_$SOURCE_PROFILE"
AGENT_CLERK="$APP_SUPPORT/clerk_profile_agent"
LOCK_FILE="$APP_SUPPORT/locks/profile-agent.lock"

if [[ ! -f "$SOURCE_CLERK/clerk_sdk.json" ]]; then
  echo "ERROR: No Clerk session at $SOURCE_CLERK/clerk_sdk.json" >&2
  echo "" >&2
  echo "Sign in once via the macOS Plot.app under profile \"$SOURCE_PROFILE\"," >&2
  echo "or pass a different source-profile that you have signed in to:" >&2
  echo "" >&2
  ls -d "$APP_SUPPORT"/clerk_profile_* 2>/dev/null | sed 's|.*/clerk_profile_|  - |' >&2 || true
  exit 1
fi

if [[ -f "$AGENT_CLERK/clerk_sdk.json" ]]; then
  echo "agent profile already seeded ($AGENT_CLERK/clerk_sdk.json)"
else
  mkdir -p "$AGENT_CLERK"
  cp "$SOURCE_CLERK/clerk_sdk.json" "$AGENT_CLERK/clerk_sdk.json"
  echo "seeded agent profile from $SOURCE_PROFILE"
fi

# Stale lock from a previous crashed run will block fresh launches. The lock
# is advisory — if no process holds it, deleting the file is safe.
if [[ -f "$LOCK_FILE" ]]; then
  if /usr/sbin/lsof "$LOCK_FILE" >/dev/null 2>&1; then
    holder_pid=$(/usr/sbin/lsof -t "$LOCK_FILE" 2>/dev/null | head -1)
    echo "agent lock held by PID $holder_pid (leaving in place)"
  else
    rm -f "$LOCK_FILE"
    echo "removed stale agent lock"
  fi
fi
