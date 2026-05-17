---
name: run-app
description: Launch the macOS Plot.app in an isolated "agent" profile and connect dart-mcp to it for hot reload, widget tree, runtime errors, and flutter_driver. Use when the user asks you to run, launch, test, or drive the Flutter app — including verifying UI changes, taking screenshots, or reproducing a bug.
---

# Run the Plot app for testing via dart-mcp

The developer keeps a Debug Plot.app and a Release Plot.app running daily.
Each holds an `InstanceLock` for its profile, so a naive `flutter run -d macos`
collides and silently exits ("Profile X already running. Sent deep link and
exiting."). You also cannot rely on `mcp__dart-mcp__launch_app` — it returns a
placeholder DTD URI immediately and does not forward `--profile`, `--user`,
`--password`, or any other entrypoint args, so the launched process either
collides with the user's instance or starts on the sign-in page.

The reliable path is to launch `flutter run` yourself with a dedicated `agent`
profile, then point dart-mcp at the DTD URI it actually emits.

## Prerequisites (one-time per machine)

The agent profile needs a cached Clerk session. If the developer has signed in
to the dev profile at least once, seed it:

```bash
bash apps/plot/scripts/agent-app-bootstrap.sh
```

This copies `clerk_profile_dev/clerk_sdk.json` to `clerk_profile_agent/` and
clears any stale agent lock. The script is idempotent — safe to re-run.

If the developer has never signed in (no `clerk_profile_dev` exists), tell
them to sign in once via their normal Debug Plot.app, then re-run.

## Launch flow

1. **Stop any previous agent run** (avoid orphaned hot-reload servers).
   macOS `pgrep -f` accepts alternation in parentheses (no `-E` flag — that
   would error on macOS). Do NOT escape the `|` as `\|`:

   ```bash
   pgrep -f '(flutter_tools.*--profile=agent|Plot\.app.*--profile=agent)' \
     | xargs -r kill
   ```

2. **Bootstrap** (idempotent):

   ```bash
   bash apps/plot/scripts/agent-app-bootstrap.sh
   ```

3. **Launch `flutter run` in the background** with the agent profile. The key
   flags are `-a --profile=agent` (forwards to `main(args)` via Dart entrypoint
   args, picked up by `CliArgs.init`), `--print-dtd`, and `--machine`:

   ```bash
   cd /Users/kris.braun/code/plot/apps/plot
   nohup flutter run -d macos -a --profile=agent --print-dtd --machine \
     > /tmp/plot-agent-run.log 2>&1 &
   echo $! > /tmp/plot-agent-run.pid
   ```

4. **Wait for `app.started`** in the log. Budget at least 90 seconds — a fresh
   incremental macOS build takes ~30-60s. Use Bash with `run_in_background`
   plus an `until` loop:

   ```bash
   until grep -qE '"event":"app.started"|"event":"app.stop"' /tmp/plot-agent-run.log; do
     sleep 2
     kill -0 "$(cat /tmp/plot-agent-run.pid)" 2>/dev/null || { echo "DIED"; break; }
   done
   ```

5. **Extract the DTD URI** from the `app.dtd` event (do NOT use the URI
   returned by `mcp__dart-mcp__launch_app` — it is a placeholder):

   ```bash
   grep -oE '"event":"app\.dtd"[^}]*"uri":"[^"]+"' /tmp/plot-agent-run.log \
     | tail -1 | sed -E 's/.*"uri":"([^"]+)".*/\1/'
   ```

6. **Connect dart-mcp** to that URI via `mcp__dart-mcp__connect_dart_tooling_daemon`.

7. **Verify** with `mcp__dart-mcp__get_runtime_errors` (should be empty) before
   driving the app. If the app landed on the sign-in page, the Clerk session
   in `clerk_profile_agent/clerk_sdk.json` is missing or expired — re-run the
   bootstrap script (it copies a fresh session from `clerk_profile_dev`).

After connect succeeds you can use any dart-mcp tool: `hot_reload`,
`get_widget_tree`, `flutter_driver`, etc. The Mac window opens on top of the
developer's running Plot instances; it will NOT steal keyboard focus (see
`apps/plot/lib/widget/window.dart` — `windowManager.show(inactive: true)`).

## Verifying a code change

Hot reload via dart-mcp after editing Dart code:

```
mcp__dart-mcp__hot_reload (with clearRuntimeErrors: true)
```

Then `get_runtime_errors` to check for new failures. For widget-level
assertions use `get_widget_tree` (pass `summaryOnly: true` to avoid context
overflow — the full tree is ~1M tokens for Plot).

## Cleanup

When done, kill the flutter run so the next agent starts clean:

```bash
kill -INT "$(cat /tmp/plot-agent-run.pid)" 2>/dev/null
```

The InstanceLock releases on process exit. The cached Clerk session and
`plot-*-agent.sqlite` DB persist, so subsequent runs reuse the same signed-in
state without re-bootstrap.

## Why this is the only reliable recipe

- **`launch_app(device: macos)`** silently fails on this repo: the developer's
  Debug Plot.app holds the `dev` profile lock; `launch_app` does not let you
  pass `--profile`, so the launched process collides and exits. The DTD URI
  it returns is a placeholder unrelated to any actually-running app.
- **`launch_app(device: chrome)`** does not work either: Flutter web does not
  pass command-line args to `main(args)`, so `--user`/`--password` auto sign-in
  can't be triggered, and the agent stalls on the OAuth popup.
- **`flutter run -t lib/main_agent.dart`** (a wrapper entrypoint that calls
  `run(['--profile=agent', ...args])`) does NOT switch entrypoints reliably on
  macOS — the build cache reuses the existing kernel snapshot for `main.dart`.
  `-a --profile=agent` is the supported path.
- **`-a --user=... -a --password=...`** also works (see
  `lib/auto_sign_in.dart`) if you need to bypass a stale Clerk cache, but
  requires a real password — pre-seeding via bootstrap is simpler.
