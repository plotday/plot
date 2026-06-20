# Click analytics coverage — design

**Date:** 2026-06-19
**Branch:** `analytics-click-coverage`

## Goal

Close gaps where user clicks produce **no PostHog event**, so analytics can
answer important behaviour questions. Today a click only emits an event when it
flows through a `Command` (`command/base.dart` `context.run` →
`Tracker.trackAction`). Many taps bypass that.

Two rules from the product owner:

1. **Standalone events** only for clicks that answer a real behaviour question.
2. **Toggles that feed a later create/send** (To-do, attachments, reply/private
   scope) get **no event of their own** — their final state rides along as
   **properties** on the eventual create/send event.
3. Per-user *counts* ("how many connectors/roles/focuses") are **person
   properties**, not click events.

Deliberately out of scope (noise): UI-local toggles (expand/collapse, focus,
dismiss), generic `select_modal` selection, onboarding-wizard internals.

## Enabling infra

`Command` cannot attach custom properties to its event today, and
`buildActionProperties` takes only fixed params (though `Tracker.trackAction`
forwards any map to PostHog). Add a reusable hook:

- `Command`: `Map<String, Object?> get eventProperties => const {};`
- `buildActionProperties(... , Map<String, Object?>? extra)` merges `extra`.
- `context.run()` passes `command.eventProperties` as `extra` (base.dart:380).

New enum values (`analytics/conventions.dart`): `EventObject.role`,
`EventAction.joined`, `EventAction.retried`. Everything else reuses existing
objects/actions.

## Bucket A — new standalone events

| Click (file:line) | Event | Mechanism |
|---|---|---|
| Join conferencing — `widget/agenda.dart` (join URL taps) | `[Action] Activity Joined` | `context.run` of a small `JoinConference` command (or `eventProperties` on the existing open) |
| Open event from agenda — `widget/agenda.dart` | `[Action] Activity Opened` | route the row tap through a command |
| Retry failed send — `widget/note.dart` | `[Action] Note Retried` | command |
| Discard failed send — `widget/note.dart` | `[Action] Note Deleted` | command (action_type differentiates) |
| Drill into note thread — `widget/note.dart`, `page/thread.dart` (`setThreadFilter`) | `[Action] Activity Filtered` | command |
| Drag-drop move in feed — `widget/activity_feed_drag.dart` / `state/priority.dart` | `[Action] Activity Moved` | emit at drop (same object/action as menu move) |

## Bucket B — properties folded onto existing events

Computed by pure helpers from the finalized `Note`/`Thread`, returned via
`eventProperties`.

- **`AddNote`** (`[Action] Note Added`): `is_todo`, `is_private`, `is_reply`,
  `recipient_scope` (`everyone`/`private`/`reply`/`custom`), `recipient_count`,
  `attachment_count`, `attachment_types`.
- **`AddThreadWithNote`** (`[Action] Activity Added`): the note props above plus
  `contact_count`, `group_count`, `thread_type` (`event`/`task`/`notes`),
  `thread_scope` (`team`/`personal`), `priority_id`.
- **Connect** (`[Action] Twist Added`): `connector`, `connector_category`,
  `is_premium`, `context` (`onboarding`/`settings`).
- **Role create/update**: switch `_CreateRole`/`_SaveRole` from
  `EventObject.priority` to `EventObject.role` so role events are distinct from
  focus events.

> Note: connector-origin threads are created server-side via sync, so client
> `Activity Added` events are inherently user-composed. Connector-vs-Plot volume
> is answered from the connect events + server data, not this client event.

## Bucket C — person properties

A small profile updater recomputes from the local stores and sets person
properties; answers "how many X per user" and (by breakdown) "how many users
have each connector".

- `Tracker.setPersonProperties(Map)` — re-identifies with the remembered
  user id (no-op before first identify).
- `refreshUserAnalyticsProfile()` (`analytics/profile.dart`) computes
  `role_count`, `focus_count` (excludes Inbox/FYI), `connector_count`,
  `connectors[]` and calls `setPersonProperties`.
- Called at: initial identify (`base.dart`), and after role/focus
  create+archive and connection add/remove commands (recompute-from-store is
  idempotent).

## Testing

- Unit tests for the pure property builders (note/thread/connect) and the
  profile-count computation.
- Unit test that `buildActionProperties(extra:)` merges and that
  `command.eventProperties` reaches the tracked map.
- `flutter analyze` clean; existing test suite green.

## Backwards compatibility

Additive only — new optional params, new enum values, new properties. No
removed/renamed fields. Old events keep firing; they just gain properties.
