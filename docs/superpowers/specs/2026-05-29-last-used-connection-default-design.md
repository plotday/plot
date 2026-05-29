# Last-used connection as the default on NewThreadPage — design

- **Date:** 2026-05-29
- **Status:** Approved (ready for implementation plan)
- **Area:** Flutter app (`apps/plot`)

## Summary

When the user opens `NewThreadPage`, the connection compose chip should default
to the connection they used **last** instead of always defaulting to "Plot
thread". "Last-used" is scoped **per-priority, falling back to global**, and
remembers **every** choice — a plain Plot thread, a twist chat, or a connector
target (Slack channel, Gmail, Linear team, …). So if the most recent thread you
filed into this priority was a Slack message, a fresh new thread here defaults
to that Slack channel; if it was a plain Plot thread, the default stays Plot
thread.

The connection-usage MRU infrastructure already exists in
`LocalPreferencesBloc` but is only half-wired: it records connector targets only
(not Plot thread / twists), its ranking method has no callers, and the recorded
key for DM-type connectors doesn't match the canonical `CreateTarget.key`. This
change finishes wiring it up and seeds the default from it.

## Goals

- A fresh `NewThreadPage` defaults its connection chip to the user's last-used
  connection for the current priority, falling back to their global last-used.
- "Last-used" reflects the user's **actual last choice**, including reverting to
  "Plot thread" — making a plain Plot thread resets the default back to Plot
  thread.
- Brand-new users / no history → unchanged behavior (default stays Plot thread).
- Graceful fallback: a since-removed channel or connection is silently ignored
  and the next-best (or Plot thread) is used.

## Non-goals

- No new persisted preference shape — reuse the existing `connectionMru`.
- No change to the connection picker modal UI or to how a connection is applied
  to the draft.
- No server/schema changes (this is local, unsynced preference state).
- No change to thread-creation paths other than the `NewThreadPage` compose
  submit.

## Current state (what exists today)

- **Default selection:** `NewThreadPageState._resolveActiveConnectionChoice()`
  (`lib/page/new_thread.dart:501`) returns `ConnectionChoice.plotThread` for any
  draft with no `CreateLinkUserAction` and no selected twist — the hardcoded
  default the chip shows.
- **MRU infra (half-built)** in `lib/state/local_preferences.dart`:
  - `connectionMru` (`Map<String, ConnectionMruEntry>`) keyed by connection key,
    each entry tracking a global `lastUsedMs` and a per-priority
    `priorityLastUsedMs` map.
  - `recordConnectionUsage({channelKey, priorityId})` (`:49`) — bumps both
    timestamps to now.
  - `rankConnectionsByMru({keys, priorityId})` (`:72`) — already implements
    exactly the *priority-bucket → global-bucket → unseen* ordering we want.
    **Currently has no callers.**
- **Recording today:** only in `AddThreadWithNote` (`lib/command/thread.dart:469`),
  gated on `createAction != null`, so Plot threads and twists are never
  recorded. It builds the key as
  `'${twistInstanceId}|${channelId}|${linkType}'`. For channel-type targets this
  matches `CreateTarget.key`; for **DM-type** targets the canonical key is
  `'${twistId}||${linkType}|${targets}'`, so DM connectors record under a key
  that never matches a target — a latent bug.
- **Canonical keys** (already stable, in `ConnectionChoice` /
  `lib/widget/connection_targets.dart`):
  - Plot thread: `PlotThreadChoice.key` = `'plot:thread'`.
  - Twist: `TwistConnectionChoice.key` = `'twist:${twist.id}'` (instance id).
  - Channel target: `CreateTarget.key` = `'${twist.id}|${channel.channelId}|${linkType.type}'`.
  - DM target: `CreateTarget.key` = `'${twist.id}||${linkType.type}|${compose.targets}'`.

## Design

### 1. Record every submitted choice, with canonical keys

Move connection-usage recording out of the `AddThreadWithNote` command and into
`NewThreadPage`'s submit handler `_onChatSubmitted` (`lib/page/new_thread.dart:756`).
This handler is the page's `onSubmitted` callback and fires on **both** submit
paths in `NoteEditor._onNewThreadSubmitted` — the note path
(`AddThreadWithNote`, `note_editor.dart:1650`) and the empty-body-link path
(`AddThreadWithLink`, `note_editor.dart:1626`).

In `_onChatSubmitted`, record the resolved connection choice's `.key` against the
draft's priority id:

- Determine the key from the draft state directly (not via `_allConnectionTargets`,
  which can race empty):
  - `_selectedTwist != null` → `'twist:${_selectedTwist!.id}'`.
  - else active `CreateLinkUserAction` present → canonical target key derived
    from the action (see helper below).
  - else → `'plot:thread'`.
- `await prefs.recordConnectionUsage(channelKey: key, priorityId: draft.priority.id.toString())`,
  wrapped in try/catch with `Tracker.captureException` (matching the existing
  call site's error handling).

**Canonical-key helper.** Add a small helper that maps a `CreateLinkUserAction`
to the exact `CreateTarget.key` string, so recording and ranking always agree
(and the DM bug is fixed):

```
channel form: '${action.twistInstanceId}|${action.channelId}|${action.linkType}'
DM form     : '${action.twistInstanceId}||${action.linkType}|${action.dmTargets}'
```

where the DM form is used when `action.isDmType` (`dmTargets` is
`'contacts'`/`'addresses'`). Place this next to `CreateTarget` in
`lib/widget/connection_targets.dart` (e.g. a `CreateLinkUserAction` → key
function, or a getter), since that file owns the producing `CreateTarget.key`.

**Remove** the now-redundant recording block in `AddThreadWithNote`
(`lib/command/thread.dart:469-479`); the page is the single recording point.

### 2. Seed the default on open

Add a thin, testable selector to `LocalPreferencesBloc`:

```dart
/// Returns the highest-ranked connection key among [candidateKeys] that has a
/// recorded use (priority-bucket beats global-bucket, per rankConnectionsByMru),
/// or null when none of the candidates has ever been used.
String? lastUsedConnectionKey({
  required List<String> candidateKeys,
  required String priorityId,
});
```

Implementation: run `rankConnectionsByMru(keys: candidateKeys, priorityId: ...)`,
take the first key, and return it only if `connectionMru.containsKey(firstKey)`
(unseen keys sort last, so a seen first key ⇔ at least one candidate has
history); otherwise return `null`.

In `NewThreadPageState._initializeDraft` (`lib/page/new_thread.dart:136`), after
`_loadConnections()`:

1. **Skip** when `widget.sharedUrl != null` — share-intent capture keeps the
   Plot-thread default so a quick Enter can't accidentally post the shared link
   to an external connector. (Calendar-slot creation via `startTime` is **not**
   skipped — the default applies normally.)
2. Skip if the draft already has a `CreateLinkUserAction` or `_selectedTwist`
   (defensive; a fresh draft has neither).
3. Build candidate keys:
   - `PlotThreadChoice.key` (`'plot:thread'`),
   - chat-eligible twists — same filter the picker uses,
     `twists.where((t) => !t.isSource && (t.threadType?.isNotEmpty ?? false))`
     → `'twist:${t.id}'`,
   - `_allConnectionTargets.map((t) => t.key)`.
4. `final key = prefs.lastUsedConnectionKey(candidateKeys: ..., priorityId: draft.priority.id.toString());`
5. Apply:
   - `key == null || key == 'plot:thread'` → no-op (keep existing default).
   - twist key → resolve the `TwistInstance` and select it **without** recording
     mention usage (an auto-selection must not reorder the mention MRU — so do
     not call the existing `_selectTwist`, which calls `recordMentionUsage`;
     set `_selectedTwist` + the `twist:` icon directly, or add a
     `recordUsage: false` path).
   - target key → find the matching `CreateTarget` in `_allConnectionTargets`
     and apply via `_applyConnectionChoice(ConnectionChoice.target(target))`.

This runs once per mount (guarded by the existing `_hasAppliedQueryParams`
one-shot in `didChangeDependencies`). After submit the route replaces
`NewThreadRoute` with `ThreadRoute`, so the next "New" remounts and re-seeds —
once-per-mount is correct.

### Edge cases

- **No history / new user:** `lastUsedConnectionKey` returns `null` → Plot-thread
  default unchanged.
- **Removed channel/connection:** its key isn't in `candidateKeys`, so it's never
  considered; the next-best seen candidate (or Plot thread) wins.
- **Auto-organize (root):** the draft priority at submit is root/default; usage
  records against root and seeds future root new-threads. Acceptable.
- **Empty-body-link submit with a connector selected:** the link path creates a
  plain Plot thread but the recorded choice is the connector that was showing on
  the chip. Negligible mismatch; not worth special-casing.

## Testing

Unit tests in `apps/plot/test/state/` against `LocalPreferencesBloc`:

- `lastUsedConnectionKey` returns the per-priority most-recent over a
  more-recent global use in another priority (priority bucket wins).
- Falls back to the global most-recent when this priority has no recorded use.
- Returns `null` when no candidate has any recorded use.
- Returns `'plot:thread'` when that was the last choice (so the caller keeps the
  default).
- DM-type canonical key round-trips: a recorded DM connector key matches the
  `CreateTarget.key` for the same connector (regression for the old
  `|null|` mismatch).

No widget test required — the selection and key logic are pure/bloc-level; the
`NewThreadPage` wiring is thin.

## Out of scope / follow-ups

- Reordering the connection **picker** by MRU (the now-wired
  `rankConnectionsByMru` could also drive picker ordering) — not part of this
  change.

## Logistics

Land on a dedicated branch/worktree — the current branch
(`theme/section-header-background`) carries unrelated agenda/theme work.
