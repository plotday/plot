#!/usr/bin/env bash
# Bootstrap an isolated, per-workspace agent profile so a dart-mcp-launched
# Plot.app does not collide with the developer's daily dev/release instances
# OR with another agent running concurrently in a different worktree.
#
# The agent profile name is derived from the workspace (the repo/worktree
# directory basename), e.g. "agent-plot" for the main checkout and
# "agent-<worktree>" for a worktree. This keeps every concurrent agent on its
# own profile, InstanceLock, local DB, and cached session. Override with
# $PLOT_AGENT_PROFILE or by passing an explicit agent-profile as $2.
#
# What it does:
#   1. Verifies a signed-in source profile exists (default: dev). Without a
#      cached Clerk session, the agent instance lands on the sign-in page.
#   2. Copies that profile's Clerk session into clerk_profile_<agent-profile>.
#      Always refreshes (overwrites) so an expired agent session gets renewed
#      from the active dev session.
#   3. Kills any orphan processes for THIS agent profile (flutter run daemons
#      and Plot.app instances launched with --profile=<agent-profile>). Other
#      workspaces' agent profiles are left untouched.
#   4. Releases any stale lock for this profile from a crashed previous run.
#
# Re-run safely. Idempotent.
#
# Usage:
#   bash scripts/agent-app-bootstrap.sh [source-profile] [agent-profile]
#
# Default source-profile is "dev". Pass "default" if you only sign in via the
# release app, or any other profile name that has a current Clerk session.
# Default agent-profile is "agent-<workspace>"; rarely need to override.

set -euo pipefail

SOURCE_PROFILE="${1:-dev}"

# Derive a per-workspace agent profile name. Distinct workspaces (main repo +
# each worktree) get distinct profiles so concurrent agents never collide.
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
sanitize_token() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' \
    | sed -E 's/-+/-/g; s/^-//; s/-$//'
}
DEFAULT_PROFILE="agent-$(sanitize_token "$(basename "$REPO_ROOT")")"
AGENT_PROFILE="${2:-${PLOT_AGENT_PROFILE:-$DEFAULT_PROFILE}}"

APP_SUPPORT="$HOME/Library/Containers/day.plot.app/Data/Library/Application Support/day.plot.app"
SOURCE_CLERK="$APP_SUPPORT/clerk_profile_$SOURCE_PROFILE"
AGENT_CLERK="$APP_SUPPORT/clerk_profile_$AGENT_PROFILE"
LOCK_FILE="$APP_SUPPORT/locks/profile-$AGENT_PROFILE.lock"

if [[ ! -f "$SOURCE_CLERK/clerk_sdk.json" ]]; then
  echo "ERROR: No Clerk session at $SOURCE_CLERK/clerk_sdk.json" >&2
  echo "" >&2
  echo "Sign in once via the macOS Plot.app under profile \"$SOURCE_PROFILE\"," >&2
  echo "or pass a different source-profile that you have signed in to:" >&2
  echo "" >&2
  ls -d "$APP_SUPPORT"/clerk_profile_* 2>/dev/null | sed 's|.*/clerk_profile_|  - |' >&2 || true
  exit 1
fi

# Always refresh the agent session from the source. If the agent session
# expired but the dev session is fresh, this picks up the renewal. Skipping
# the copy when the file exists (the previous behavior) left agents stranded
# on the sign-in page after the cached token aged out.
mkdir -p "$AGENT_CLERK"
cp "$SOURCE_CLERK/clerk_sdk.json" "$AGENT_CLERK/clerk_sdk.json"
echo "refreshed $AGENT_PROFILE Clerk session from $SOURCE_PROFILE"

# Kill any orphan processes for THIS agent profile from a prior run. Killing
# the flutter run daemon (the `flutter_tools` invocation) does NOT terminate
# the spawned Plot.app — it just orphans it, leaving the InstanceLock held and
# blocking the next launch. Kill both halves explicitly here. The pattern is
# scoped to this profile so a concurrent agent in another worktree is untouched.
#
# Filter pgrep results to exclude our own pipeline so the script does not
# match itself when run from a shell that puts the command line in argv.
ORPHAN_RE="(flutter_tools.*--profile=$AGENT_PROFILE|Plot\.app.*--profile=$AGENT_PROFILE)"
self_pid=$$
orphan_pids=$(pgrep -f "$ORPHAN_RE" 2>/dev/null \
  | grep -v "^$self_pid\$" || true)
if [[ -n "$orphan_pids" ]]; then
  echo "killing orphan $AGENT_PROFILE processes: $orphan_pids" | tr '\n' ' '
  echo
  # shellcheck disable=SC2086
  kill $orphan_pids 2>/dev/null || true
  # Give them a moment to exit cleanly before checking the lock.
  for _ in 1 2 3 4 5; do
    sleep 1
    still=$(pgrep -f "$ORPHAN_RE" 2>/dev/null \
      | grep -v "^$self_pid\$" || true)
    [[ -z "$still" ]] && break
  done
  # If anything is still alive, force-kill it. Holding the InstanceLock is
  # the failure mode we are guarding against.
  remaining=$(pgrep -f "$ORPHAN_RE" 2>/dev/null \
    | grep -v "^$self_pid\$" || true)
  if [[ -n "$remaining" ]]; then
    echo "force-killing stubborn $AGENT_PROFILE processes: $remaining" | tr '\n' ' '
    echo
    # shellcheck disable=SC2086
    kill -9 $remaining 2>/dev/null || true
    sleep 1
  fi
fi

# Stale lock from a previous crashed run will block fresh launches. The lock
# is advisory — if no process holds it, deleting the file is safe.
if [[ -f "$LOCK_FILE" ]]; then
  if /usr/sbin/lsof "$LOCK_FILE" >/dev/null 2>&1; then
    holder_pid=$(/usr/sbin/lsof -t "$LOCK_FILE" 2>/dev/null | head -1)
    echo "$AGENT_PROFILE lock still held by PID $holder_pid after kill (leaving in place)" >&2
    exit 1
  else
    rm -f "$LOCK_FILE"
    echo "removed stale $AGENT_PROFILE lock"
  fi
fi
