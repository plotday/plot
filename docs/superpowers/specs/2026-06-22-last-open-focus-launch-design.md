# Last open focus as the launch fallback — design

**Date:** 2026-06-22
**Status:** Approved design, pending implementation plan
**Scope:** Flutter app (`apps/plot/`). No schema, no sync, no server changes.

## Problem

On launch the app almost always opens **Personal > Inbox**, regardless of what
the user was last working on. On desktop (multi-panel) the `/` route forwards to
`/p/{NowLoaded.priority}`, and with nothing scheduled or running, that
`priority` getter falls through its whole cascade to `defaultPriority` — the
oldest `is_inbox = true` focus, i.e. Personal > Inbox.

The user wants the fallback to be the **last focus they deliberately opened**,
*except* when a scheduled event or focus block is active right now, in which case
that should still determine the focus.

## Current behavior (reference)

`NowLoaded.priority` (`apps/plot/lib/state/now_state.dart:265`) is the canonical
"current priority" and drives the `/` redirect, focus commands, and re-sign-in
navigation:

```dart
Priority get priority =>
    context ??                         // 1. what you're viewing (null at cold start)
    scheduled.firstOrNull?.priority ?? // 2. in-progress scheduled event
    _activeFocusBlockPriority() ??     // 3. user-scheduled focus block covering now
    session?.priority ??               // 4. running focus session (pomodoro)
    defaultPriority;                   // 5. fallback → Personal Inbox
```

Relevant facts established during exploration:

- **No "last open focus" is persisted anywhere today.** `context` is in-memory
  only and is `null` at every cold start.
- **Deep links are deliberately preserved.** `RootPage` only governs the `/`
  route; opening `/p/<id>` or `/t/<id>` never runs the cascade.
  `PostAuthNavigationGate` only bounces to the default priority on a genuine
  re-sign-in, never on cold start / refresh.
- **Layouts differ.** Multi-panel (desktop) opens *into a focus's threads*
  (`/p/{priority}`). Single-panel (mobile) opens to `/priorities` — a *list* of
  focuses with `selected = NowLoaded.context` (null at launch → none
  highlighted). The reported symptom is the desktop path.
- **`ChangeCurrentPriority`** (`apps/plot/lib/command/priority.dart:147`) is the
  single command every deliberate focus pick flows through — sidebar tree
  (`widget/priority.dart:209`), header picker (`widget/unified_header.dart:1008`),
  agenda block tap (`widget/agenda.dart:1473`), command palette
  (`command/priority.dart:276`). It calls `nowBloc.setContext(...)`. Automatic
  context updates (page-sync after routing, deep-link loads, event/block
  auto-select) go through *other* `setContext` call sites, **not** this command.

## Decisions (from brainstorming)

1. **What to record:** Only focuses the user *actively picks* (sidebar / header /
   command / agenda tap) — not automatic event/focus-block/deep-link navigation.
2. **Session precedence:** A running focus session still outranks the new
   last-open fallback.
3. **Scope:** Desktop / multi-panel launch + re-sign-in only. Mobile
   single-panel keeps landing on the focus list (unchanged).
4. **Storage:** Device-local (not synced) — each device remembers its own last
   focus, matching the in-memory `context` semantics.

## Design

### New precedence chain

Insert one rung above the Inbox fallback:

```
1. context            (what you're viewing — null at cold start)
2. in-progress event  ─┐ "current scheduled event or focus block" — still win
3. active focus block ─┘
4. running session     (pomodoro — still wins, per decision 2)
5. last open focus     ← NEW
6. defaultPriority     (Personal Inbox — only when 1–5 are all empty)
```

### Record (deliberate picks → device-local pref)

- Hook into `ChangeCurrentPriority.run()` (`command/priority.dart:147`).
- When the selected `priority != null` (a real focus, including a deliberately
  chosen Inbox), persist that focus's UUID to `ProfilePreferences` under key
  `last_open_focus` (string, `Uuid.toString()`).
- When `priority == null` (the synthetic **"Everything"** feed), do **not**
  record — leave the previously stored real focus intact.
- `ProfilePreferences` (`apps/plot/lib/util/profile_preferences.dart`) is the
  app's profile-isolated `SharedPreferences` wrapper; writes are
  `await`-ed/fire-safely as the existing pref call sites do.

Because automatic `setContext` callers (page-sync, deep-link load, event/block
auto-select) do not run `ChangeCurrentPriority`, they never overwrite the memory.
This is what makes "only focuses you pick" hold.

### Restore (cascade rung 5)

- `NowBloc.start()` reads `last_open_focus` once and carries the parsed
  `Uuid? lastOpenFocusId` in `NowLoaded`.
- The `priority` getter resolves `lastOpenFocusId` against the loaded
  `priorities` list — the same pattern as `_activeFocusBlockPriority()` (look up
  by id, return the `Priority` or `null`) — and slots the result in at rung 5,
  just above `defaultPriority`.
- Resolution returns `null` (→ falls through to Personal Inbox) when: no pref
  exists yet (first launch), or the stored focus is archived/deleted/not in the
  current list. Same robustness as the existing focus-block resolution.
- Store the **id**, resolve in the getter (don't cache a resolved `Priority` in
  state) so a focus that later disappears can't strand a dangling reference.

`lastOpenFocusId` only matters when `context` is null (cold start). Once the user
navigates, `context` is set and outranks it, so the in-state value does not need
to be re-read mid-session. (Updating it in-state on each pick is optional and not
required for correctness.)

### Re-sign-in consistency

`root_provider.dart:221` currently hardcodes
`nowBloc.loadedState.defaultPriority.id` when bouncing after a re-sign-in. Change
it to `nowBloc.loadedState.priority.id` (the cascade) so a re-sign-in also
honors an active event/block or the last-open focus instead of always Inbox.
Cold-start / deep-link behavior is unchanged (still gated by
`PostAuthNavigationGate`).

### Why not the alternatives

- **Special-case only `RootPage`:** duplicates the cascade and lets `RootPage`
  drift out of sync with the canonical `NowLoaded.priority`. Rejected.
- **Persist the full last route/URL:** drags in thread deep-links, "Everything"
  mode, and scroll state, and fights the deliberate "a deep link always wins"
  design. Over-scoped. Rejected (YAGNI).

## Testing

Flutter-only; pure-logic where possible.

- **Cascade getter** (bulk of coverage): `lastOpenFocusId` resolves and slots at
  rung 5; an in-progress event, an active focus block, and a running session
  each still outrank it; an archived/missing/absent id falls through to
  Personal Inbox; no-pref reproduces today's behavior exactly.
- **Record:** `ChangeCurrentPriority` persists a real focus pick to
  `last_open_focus`; picking "Everything" does not overwrite it; a deliberate
  Inbox pick *is* recorded.
- **Re-sign-in:** navigation target uses the cascade (`priority`) not
  `defaultPriority`.
- `ProfilePreferences` is faked via `SharedPreferences.setMockInitialValues`
  (existing test pattern).

## Out of scope

- Mobile single-panel highlight restore (decision 3).
- Persisting thread deep-links, "Everything" mode, or scroll position.
- Any cross-device sync of the last-open focus.
- Schema / server / connector changes.
