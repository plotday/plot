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

The reliable path is to launch via `apps/plot/scripts/agent-app-launch.sh`,
which wraps `flutter run -d macos --machine --print-dtd` with bootstrap,
orphan cleanup, and retry-on-transient-failure (see "Failure modes" below).

## Prerequisites (one-time per machine)

The agent profile needs a cached Clerk session. If the developer has signed in
to the dev profile at least once, the launcher will copy it automatically.
If they have NEVER signed in (no `clerk_profile_dev` exists), tell them to
sign in once via their normal Debug Plot.app, then re-run.

## Launch flow

Run the launcher and read the DTD URI it writes out. The launcher is
idempotent and handles its own cleanup, so you can re-run it freely.

```bash
bash apps/plot/scripts/agent-app-launch.sh
```

On success (exit 0) it prints the DTD URI and leaves three files:

- `/tmp/plot-agent-run.log` — full `flutter run --machine` log
- `/tmp/plot-agent-run.pid` — daemon PID (kept alive for hot reload)
- `/tmp/plot-agent-dtd.uri` — the DTD URI to feed dart-mcp

Connect dart-mcp:

```bash
DTD_URI=$(cat /tmp/plot-agent-dtd.uri)
```

Then call `mcp__dart-mcp__connect_dart_tooling_daemon` with `uri=$DTD_URI`.

After connect succeeds you can use any dart-mcp tool: `hot_reload`,
`get_widget_tree`, `flutter_driver`, etc. The Mac window opens on top of the
developer's running Plot instances; it will NOT steal keyboard focus (see
`apps/plot/macos/Runner/AppDelegate.swift` — Debug builds yield activation
back to the launcher on first `applicationDidBecomeActive`).

Verify with `mcp__dart-mcp__get_runtime_errors` (should be empty) before
driving the app. If the app landed on the sign-in page, the dev profile's
Clerk session is itself expired — sign in once via the developer's Debug
Plot.app and re-run the launcher (it always refreshes from `dev`).

## Verifying a code change

Hot reload via dart-mcp after editing Dart code:

```
mcp__dart-mcp__hot_reload (with clearRuntimeErrors: true)
```

Then `get_runtime_errors` to check for new failures. For widget-level
assertions use `get_widget_tree` (pass `summaryOnly: true` to avoid context
overflow — the full tree is ~1M tokens for Plot).

## Cleanup

When done, kill the flutter run daemon AND the spawned Plot.app. Killing
the daemon alone leaves Plot.app holding the `agent` profile InstanceLock,
which blocks the next launch — the launcher will clean that up on the
next run, but doing it now is tidier:

```bash
kill -INT "$(cat /tmp/plot-agent-run.pid)" 2>/dev/null
sleep 1
pgrep -f 'Plot\.app.*--profile=agent' | xargs -r kill
```

The cached Clerk session and `plot-*-agent.sqlite` DB persist, so subsequent
runs reuse the same signed-in state.

## Failure modes the launcher handles

1. **Orphan Plot.app from a prior agent run.** Killing the flutter run
   daemon does not propagate to the spawned `Plot.app --profile=agent`, so
   the InstanceLock stays held and the next `flutter run` collides. The
   bootstrap step kills orphans before starting, then re-verifies the lock
   is releasable.

2. **mDNS-discovery timeout (the original "no `app.dtd` ever" bug).**
   `flutter run --machine` on macOS discovers the VM service via Bonjour.
   Occasionally the daemon's discovery times out before the engine
   publishes — it then emits `app.stop` with no preceding `app.debugPort`
   or `app.dtd`, and the daemon process exits. The launched binary stays
   alive but unattached. The launcher detects this (app.stop OR daemon
   death OR 120s without app.dtd), cleans up, and retries up to 3 times.

3. **Stale lock file pointing at a dead PID.** The bootstrap removes lock
   files whose holder PID is no longer alive (`lsof` returns empty).

## Tuning

Environment variables (rarely needed):

- `PLOT_AGENT_LAUNCH_RETRIES` — attempts before giving up (default 3).
- `PLOT_AGENT_LAUNCH_TIMEOUT` — seconds to wait for `app.dtd` per
  attempt (default 120). Raise for a fresh checkout where the first
  `flutter run` does a full macOS Xcode build.

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
  requires a real password — the launcher's auto-refresh of the cached
  session from `dev` is simpler.
