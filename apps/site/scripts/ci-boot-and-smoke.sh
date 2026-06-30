#!/usr/bin/env bash
# Boots the freshly-built site worker (apps/site/build/server) under a local
# wrangler/miniflare runtime and runs the site smoke test against it.
#
# This is the heart of the build-boot PR gate: a bundle that compiles fine but
# crashes the worker at module init (e.g. the vite 8.1.0 Clerk
# `setErrorThrowerOptions is not defined` regression that took plot.day down)
# fails here BEFORE it can be deployed. `wrangler deploy` never executes the
# bundle, so building alone is not enough — we must actually run it.
#
# Run from the apps/site directory.
set -uo pipefail

BASE="http://127.0.0.1:8788"
SERVER_DIR="build/server"
LOG="$PWD/.wrangler-dev.log"

if [ ! -f "$SERVER_DIR/index.js" ]; then
  echo "::error::$SERVER_DIR/index.js not found — did 'nx build @plotday/site' run?"
  exit 1
fi

# Placeholder Clerk vars so the worker can boot. The smoke check is
# worker-health only (looks for the x-plot-error header / crash markers, not a
# rendered 200), so real keys are not required — a module-init crash fails
# regardless of auth. The publishable key is a well-formed pk_test (base64
# decodes to "clerk.smoke.test$") so the Clerk SDK accepts its format.
cat > "$SERVER_DIR/.dev.vars" <<EOF
CLERK_PUBLISHABLE_KEY=${CLERK_PUBLISHABLE_KEY:-pk_test_Y2xlcmsuc21va2UudGVzdCQ}
CLERK_SECRET_KEY=${CLERK_SECRET_KEY:-sk_test_smoke}
EOF

export CI=true
export WRANGLER_SEND_METRICS=false

# cd into the built worker dir so only its generated wrangler.json is used
# (avoids the "found two wrangler configs" conflict with apps/site/wrangler.jsonc).
( cd "$SERVER_DIR" && pnpm exec wrangler dev --local --ip 127.0.0.1 --port 8788 ) > "$LOG" 2>&1 &
WRANGLER_PID=$!
# Kill the wrangler process *and* its workerd child on exit — wrangler spawns
# workerd as a child that otherwise outlives a plain `kill` and keeps port 8788
# bound (which silently breaks a subsequent run against a stale worker).
trap 'pkill -P "$WRANGLER_PID" 2>/dev/null || true; kill "$WRANGLER_PID" 2>/dev/null || true' EXIT

# Wait until the worker answers with any HTTP status (up to ~90s). A bad-key
# 500 still counts as "up" — we only need it listening to run the smoke check.
ready=false
for _ in $(seq 1 90); do
  code=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/" 2>/dev/null || true)
  if printf '%s' "$code" | grep -qE '^[1-5][0-9][0-9]$'; then ready=true; break; fi
  if ! kill -0 "$WRANGLER_PID" 2>/dev/null; then
    echo "::error::wrangler dev exited before becoming ready"; cat "$LOG"; exit 1
  fi
  sleep 1
done

if [ "$ready" != true ]; then
  echo "::error::worker did not become ready within 90s"; cat "$LOG"; exit 1
fi

# Primary signal: x-plot-error header / crash markers (no status assertion —
# placeholder keys may legitimately render a non-200).
node scripts/smoke-test-site.mjs --url "$BASE" --no-status-check
smoke=$?

# Backstop: a crash that escapes workers/app.ts's try/catch (a true top-of-module
# throw) surfaces as an uncaught exception in wrangler's log rather than an
# x-plot-error response. Fail on that too.
if grep -qiE 'Uncaught|ReferenceError|is not defined|threw exception' "$LOG"; then
  echo "::error::worker logged an uncaught exception during boot:"
  grep -iE 'Uncaught|ReferenceError|is not defined|threw exception' "$LOG" || true
  exit 1
fi

exit "$smoke"
