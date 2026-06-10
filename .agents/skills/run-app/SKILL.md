---
name: run-app
description: Launch the macOS Plot.app in an isolated, per-workspace agent profile and connect dart-mcp to it for hot reload, widget tree, runtime errors, and flutter_driver. Use when the user asks you to run, launch, test, or drive the Flutter app — including verifying UI changes, taking screenshots, or reproducing a bug.
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

## Concurrent agents — the profile is per-workspace

The launcher derives its agent profile name from the workspace directory:
`agent-plot` for the main checkout and `agent-<worktree>` for a worktree (the
sanitized basename of the repo/worktree root). Everything keyed on that name —
the `InstanceLock`, the cached Clerk session, the local Drift DB, the
`/tmp/plot-<profile>-*` state files, and the orphan-cleanup process match — is
therefore isolated per workspace, so **two agents running concurrently in
different worktrees do not collide**. You normally don't need to think about
the name; just run the launcher from your workspace. Override with
`PLOT_AGENT_PROFILE=<name>` only if you need a specific profile (e.g. two
worktrees whose directory basenames happen to collide).

Two consequences worth knowing:

- Each profile has its **own empty Drift DB** on first launch and does a full
  initial sync from the server — same as the old single `agent` profile, just
  one per workspace. Expect a few seconds of first-run sync.
- All agent profiles **share the developer's underlying Clerk session** (copied
  from `dev`). This is the same session dev + agent already share today, so
  parallel use is fine in practice.

## Prerequisites (one-time per machine)

The agent profile needs a cached Clerk session. If the developer has signed in
to the dev profile at least once, the launcher copies it into this workspace's
profile automatically. If they have NEVER signed in (no `clerk_profile_dev`
exists), tell them to sign in once via their normal Debug Plot.app, then
re-run. (As a fallback for a missing/expired dev session you can pass
credentials directly — see "Why this is the only reliable recipe" — but the
copied session is simpler and needs no password.)

## Launch flow

Run the launcher and read the DTD URI it writes out. The launcher is
idempotent and handles its own cleanup, so you can re-run it freely.

```bash
bash apps/plot/scripts/agent-app-launch.sh
```

On success (exit 0) it prints the resolved profile name, the DTD URI, and the
paths of three per-profile files:

- `/tmp/plot-<profile>-run.log` — full `flutter run --machine` log
- `/tmp/plot-<profile>-run.pid` — daemon PID (kept alive for hot reload)
- `/tmp/plot-<profile>-dtd.uri` — the DTD URI to feed dart-mcp

`<profile>` is the per-workspace name (e.g. `agent-plot`) — read it from the
launcher's `profile:` / `dtd uri:` output lines rather than hardcoding it.

Connect dart-mcp by passing the printed DTD URI straight to
`mcp__dart-mcp__connect_dart_tooling_daemon` (`uri=ws://…`). If you prefer to
read it from the file, use the `dtd uri:` path the launcher printed, e.g.:

```bash
DTD_URI=$(cat /tmp/plot-agent-plot-dtd.uri)   # path is profile-specific
```

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

## Driving the app with flutter_driver

The launcher passes `-a --enable-driver-extension`, so the app installs a
custom `DriverBinding` (`apps/plot/lib/driver_binding.dart`) that registers
the flutter_driver VM service extension AND disables frame sync. This lets
`mcp__dart-mcp__flutter_driver` issue taps, text entry, scroll, screenshot,
and waitFor commands against the live app over the same DTD connection.

### Why a custom binding (not `enableFlutterDriverExtension`)

Plot has continuous transient animations (super_editor cursor blink, etc.).
With stock frame sync on, every finder-based command first waits for
`SchedulerBinding.transientCallbackCount == 0` before AND after running the
finder, and that condition is essentially never true while animations are
active — every command times out with `TimeoutException: Future not
completed`. The custom binding dispatches `set_frame_sync=false` against
the extension in its first post-frame callback. dart-mcp's `flutter_driver`
tool can't send `set_frame_sync` itself (its `command` field is a closed
enum that does not include it).

### Workflow

1. **Find the widget.** Call `get_widget_tree` (with `summaryOnly: true`)
   first to discover the actual widget runtimeTypes, text, and tooltips on
   screen. The full tree is ~1M tokens; the summary fits but is still
   large, so search it for the label or type you expect.
2. **Pick a finder.**
   - `ByText` — matches `Text` and `RichText` widgets by exact string. Use
     for buttons, labels, and menu items.
   - `ByType` — match by `widget.runtimeType.toString()` (e.g.
     `MultiBlocProvider`, `App`, `FTextField`).
   - `ByTooltipMessage` — icon-only buttons that expose a tooltip.
   - `ByValueKey` — only works when the widget has a `Key(...)`; most Plot
     widgets do not, so prefer `ByText`/`ByTooltipMessage`.
   - `BySemanticsLabel` — accessibility-label fallback.
   - `Descendant` / `Ancestor` — disambiguate when multiple matches exist;
     pass nested finders via `of` and `matching`.
3. **`ByText` does not see super_editor content.** Thread titles and notes
   are rendered through `super_editor`'s document layout, not `Text` /
   `RichText`. `ByText="Welcome to Plot!"` will time out even though the
   string is on screen. For super_editor content, screenshot to confirm
   what's visible, then drive surrounding chrome (`ByType="SuperReader"`,
   tooltips, etc.) instead of the document text.
4. **Wait, then act.** For taps, `waitForTappable` + `tap` is more
   reliable than a bare `tap` when the target has just appeared.
5. **Verify with screenshot.** After every state-changing command, take a
   screenshot to confirm the actual effect — finders that "succeed" can
   still target the wrong element when multiple match.

### Examples (verified working against the live agent app)

Tap a sidebar entry (real `Text` widget):

```
mcp__dart-mcp__flutter_driver
  command: tap
  finderType: ByText
  text: Add connection
```

Type into the currently focused field (e.g. a search input after tap):

```
mcp__dart-mcp__flutter_driver
  command: enter_text
  text: Linear
```

`enter_text` does NOT take a finder — Flutter targets the currently
focused text field. Tap the field first.

Scroll a list entry into view:

```
mcp__dart-mcp__flutter_driver
  command: scrollIntoView
  finderType: ByText
  text: Inbox
  alignment: "0.0"
```

Take a screenshot (returned inline by dart-mcp):

```
mcp__dart-mcp__flutter_driver
  command: screenshot
```

### Troubleshooting

- **"The flutter driver extension is not enabled."** The app was launched
  without `--enable-driver-extension`, or in release mode, or the
  DriverBinding never ran. Re-launch via
  `bash apps/plot/scripts/agent-app-launch.sh` and confirm
  `lib/driver_binding.dart` exists.
- **All finder commands time out, `get_health` succeeds.** Frame sync was
  not disabled. The launcher writes the flutter run log to
  `/tmp/plot-<profile>-run.log` (path printed on launch); grep it for
  `set_frame_sync` errors. The
  `DriverBinding.initServiceExtensions` dispatches `set_frame_sync=false`
  in its first `addPostFrameCallback`, so the disable only takes effect
  after the root widget mounts — if you launched the agent app on the
  sign-in page (no root content), let it advance first.
- **`enter_text` does nothing.** The driver's text emulation only works
  when a Flutter `TextField` / `FTextField` has focus. Tap the field
  first; verify focus via screenshot before typing.
- **Hot restart drops the flag.** `mcp__dart-mcp__hot_restart` re-runs
  `main([])` with empty args, so `CliArgs.enableDriverExtension` becomes
  false on restart and the driver extension is gone. After hot restart,
  re-launch via the script. Hot reload preserves the binding and is
  safe.

## Cleanup

When done, kill the flutter run daemon AND the spawned Plot.app. Killing
the daemon alone leaves Plot.app holding this profile's InstanceLock,
which blocks the next launch — the launcher will clean that up on the
next run, but doing it now is tidier. Use this workspace's profile name
(the launcher printed it; e.g. `agent-plot`) so you only kill your own app,
not a concurrent agent's:

```bash
PROFILE=agent-plot   # the profile the launcher printed for THIS workspace
kill -INT "$(cat /tmp/plot-$PROFILE-run.pid)" 2>/dev/null
sleep 1
pgrep -f "Plot\.app.*--profile=$PROFILE" | xargs -r kill
```

The cached Clerk session and `plot-*-$PROFILE.sqlite` DB persist, so subsequent
runs reuse the same signed-in state.

## Failure modes the launcher handles

1. **Orphan Plot.app from a prior agent run.** Killing the flutter run
   daemon does not propagate to the spawned `Plot.app --profile=<profile>`,
   so the InstanceLock stays held and the next `flutter run` collides. The
   bootstrap step kills orphans **for this workspace's profile only** before
   starting (a concurrent agent's app in another worktree is left alone),
   then re-verifies the lock is releasable.

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
  `run(['--profile=agent-…', ...args])`) does NOT switch entrypoints reliably
  on macOS — the build cache reuses the existing kernel snapshot for
  `main.dart`. `-a --profile=<agent-profile>` is the supported path.
- **`-a --user=... -a --password=...`** also works (see
  `lib/auto_sign_in.dart`) if you need to bypass a stale Clerk cache, but
  requires a real password — the launcher's auto-refresh of the cached
  session from `dev` is simpler.
