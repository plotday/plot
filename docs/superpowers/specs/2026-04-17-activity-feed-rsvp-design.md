# Activity Feed RSVP

**Status:** Approved
**Date:** 2026-04-17
**Author:** Kris Braun

## Problem

Calendar event threads appear in the priority activity feed, but without the RSVP UX the agenda provides. Users can see an event was added to their feed but can't respond to it (Attend / Skip) without navigating into the thread or switching to the agenda.

For recurring events this is especially awkward: the activity feed shows a single thread (the series), not per-occurrence rows like the agenda, so "which occurrence does this RSVP apply to?" needs a defined answer before we can surface the UX.

## Goals

- Event threads in the activity feed show the same RSVP controls that the agenda shows for the equivalent event: Attend + Skip when the user hasn't responded and has co-attendees; single `ToggleRsvp` otherwise.
- For a recurring event, the feed picks a single **representative occurrence** (next upcoming; else most recent past) and displays RSVP info for it.
- Threads where the whole series has been declined remain in the feed, and clicking Attend re-accepts the series (not just one occurrence).
- No changes to the `/sync/schedule/status` endpoint, the RSVP commands, or server semantics. All work is client-side.

## Non-goals

- RSVP on native Plot schedules (non-link-schedule events). Only synced calendar events (`hasLinkSchedule`) are in scope, matching the agenda's existing `isCalendarEvent` gate.
- Todo bases (threads that happen to carry a schedule but are user-created todos). Existing RSVP gate `!isTodoBase` continues to apply.
- Changing the agenda's per-occurrence RSVP behavior.
- Changing the schedule-date header / metadata row layout in the activity feed. It already exists for `hasLinkSchedule`; it will now reflect the representative occurrence automatically.

## Background

### Where the gate sits today

`apps/plot/lib/widget/thread.dart:1032` computes:

```dart
final isTodoBase = activity.todo && !activity.isLinkScheduleInstance;
final showEventButtons = showEventTiming && !isTodoBase;
// ...
final isCalendarEvent = showEventButtons && activity.isLinkScheduleInstance;
```

Two things currently suppress RSVP in the feed:

1. `showEventTiming` is **not passed** at `apps/plot/lib/page/priority.dart:1826` (the activity-feed invocation of `ThreadWidget`), so `showEventButtons` is false.
2. Activity-feed threads carry the **base** schedule row (the series), so `isLinkScheduleInstance` is false. The agenda flips it to true when it materializes per-occurrence threads (`apps/plot/lib/store/thread.dart:1910, 1941, 1960`).

### How the agenda picks occurrences

`Thread.generateOccurrences(BoundedDateRange range)` at `apps/plot/lib/store/thread.dart:3792` wraps the `rrule` package and emits one `Thread` per instance inside the range, copying the base schedule's `currentUserStatus` onto each generated occurrence schedule row (line 3873). Persisted occurrence **overrides** (schedule rows where `occurrence IS NOT NULL`) replace matching generated entries; archived overrides remove cancelled instances (`store/thread.dart:1925–1932`).

### Existing RSVP command semantics

`apps/plot/lib/command/thread.dart:500–599`:

- `AttendRsvp`, `SkipRsvp`: always POST `{thread_id, status}` — **series-level**. Used when the user has no prior RSVP.
- `ToggleRsvp`: computes `isOccurrenceLevel = hasExistingRsvp && thread.occurrence != null`. If true, POSTs `{thread_id, occurrence, status}` — **occurrence-level**. Otherwise series-level.

This rule is sufficient for the agenda (every recurring row is an occurrence instance — any existing RSVP on one such instance is assumed to have been set at the occurrence level). It is **not** sufficient for the activity feed: a feed thread's representative occurrence may have `occurrence != null` while the user's existing RSVP was set at the series level and merely copied into the instance. Toggling it as occurrence-level would leave the series "skip" in place and flip only one instance.

## Design

### Representative occurrence

A new helper on `Thread`:

```dart
/// Returns a thread copy whose schedule row is the single occurrence to
/// display/act on in the activity feed: the earliest upcoming (end >= now),
/// else the latest past (end < now), within a bounded window around now.
/// For non-recurring events, returns `this`. Returns null if the event is
/// not a feed-eligible calendar event, or no qualifying occurrence lies
/// within the lookup window.
Thread? representativeForFeed({required DateTime now, Duration lookAhead, Duration lookBack});
```

Internal shape:

1. **Gate.** If `!hasLinkSchedule` or `isTodoBase` (todo AND not already an instance), return `this` unchanged — the caller decides whether to use it. Alternatively, return `this` only when it qualifies and `null` otherwise. (See "Call site".)
2. **Non-recurring.** Return `this` (the base schedule row already is the only occurrence).
3. **Recurring.**
   - Build a window `[now - lookBack, now + lookAhead]` and call `generateOccurrences(window)` to materialize instances.
   - Apply persisted overrides (schedule rows with `occurrence IS NOT NULL`): replace matching generated entries; drop entries whose override is archived. This mirrors `store/thread.dart:1925–1932` — factor the merge out into a shared private helper.
   - From the merged set, pick the **earliest** with `end >= now`. If none, pick the **latest** with `end < now`.
   - Return `_fromStore(..., schedule: chosen, isLinkScheduleInstance: true, ...)`. The chosen schedule row is either the original override row (already persisted) or the generated row from step 1, which carries the rrule-derived `occurrence` string and copies `currentUserStatus` from the series.

### Tracking the RSVP origin

To fix the series-vs-occurrence toggle bug, the representative thread must remember whether the RSVP was inherited from the series or set on an occurrence override. Add a field:

```dart
final bool rsvpInheritedFromSeries; // true => currentUserRsvp came from the series row
```

Set it to `true` when the chosen row is a generated instance (rrule copy) OR when the override row's own `schedule_contact` has no rows for any of the user's linked contacts (i.e. the status visible on the override is still the series-level copy). Set it to `false` when the override row carries the user's own `schedule_contact` rows.

Computing "which rows carry the user's RSVP" at representative-resolution time requires either:
- a cheap lookup into the schedule_contact data that's already hydrated for the representative schedule (preferred — `scheduleContacts` on the Thread is derived from the schedule's contacts payload, and currently the agenda already pulls series-level `currentUserStatus` during generation), OR
- a flag on the `ScheduleRow` indicating "this row has an occurrence-specific `schedule_contact` for the current user".

We'll use the first: the representative Thread wraps its chosen schedule row, from which `scheduleContacts` is already derived. The resolver filters that list for the user's linked contacts; if any match, the RSVP is occurrence-level.

### ToggleRsvp: honor the origin

Update `ToggleRsvp.run` (`command/thread.dart:526`):

```dart
final targetsOccurrence =
    hasExistingRsvp &&
    thread.occurrence != null &&
    !thread.rsvpInheritedFromSeries;
```

Outside the activity feed, `rsvpInheritedFromSeries` is `false` by default on agenda-materialized threads (they already behave as occurrences), so current agenda behavior is preserved.

### Call site

`apps/plot/lib/page/priority.dart:1826`: when emitting the activity-feed item, resolve the representative and pass `showEventTiming: true`:

```dart
final rep = agendaActivity.thread.representativeForFeed(
  now: agendaActivity.now,
  lookAhead: const Duration(days: 60),
  lookBack: const Duration(days: 60),
);
// If rep is null (no qualifying occurrence), fall back to the base thread
// without showEventTiming — the thread still shows, just no RSVP UI.
return [
  ThreadWidget(
    key: ValueKey('feed_activitywidget_${agendaActivity.thread.id}'),
    activity: rep ?? agendaActivity.thread,
    selected: state.thread != null &&
        agendaActivity.thread.id == state.thread!.id,
    now: agendaActivity.now,
    focusNode: focusNode,
    context: state.context,
    showSubPriority: true,
    bump: false,
    showEventTiming: rep != null,
  ),
];
```

Notes on the selected-match check: `ThreadList.selected` currently compares on `thread.id`. That still matches correctly when the representative and the base share an id (they do — `_fromStore` is called with the same activity row).

### Non-recurring events

Fall through cleanly. For non-recurring link schedules, the base schedule is the only occurrence, so:
- `generateOccurrences` path isn't used (the resolver short-circuits via `!recurring`).
- The representative is `this` but wrapped with `isLinkScheduleInstance: true` and `rsvpInheritedFromSeries: false` (the user's `schedule_contact` is on this row directly).

Keeping `isLinkScheduleInstance: true` is consistent with the agenda, where non-recurring link schedules are already rendered as link schedule instances.

### Declined-series behavior

When the user has skipped the series:
- The representative's `currentUserRsvp` is `'skip'` (copied from series).
- `needsRsvp = currentUserRsvp == null && hasOtherAttendees` is false, so we show `ToggleRsvp`.
- `rsvpInheritedFromSeries` is true (the chosen row's `schedule_contact` has no occurrence-specific user rows), so `targetsOccurrence` is false.
- Clicking Attend → POSTs `{thread_id, status: 'attend'}` with no `occurrence` → server flips the series-level `schedule_contact` back to `'attend'`. Matches user-stated expectation.

## Edge cases

| Case | Behavior |
|---|---|
| Non-recurring calendar event, user not responded, has other attendees | Attend + Skip shown, same as agenda |
| Non-recurring event, user already responded | `ToggleRsvp`, same as agenda |
| Recurring, upcoming instance exists | Representative = earliest upcoming; RSVP UI acts on it (series or occurrence per origin rule) |
| Recurring, only past instances within window | Representative = latest past; RSVP UI acts on it |
| Recurring, nothing in ±60d window | `rep = null` → no RSVP UI; thread still shows in feed |
| Whole series declined | Thread visible in feed; `ToggleRsvp(Attend)` re-accepts series (no `occurrence` sent) |
| One occurrence override has occurrence-level RSVP; series is "attend" | On that representative: `rsvpInheritedFromSeries=false`; `ToggleRsvp` targets that occurrence |
| Upcoming occurrence is archived (cancelled), past instances exist | Representative = latest past (archived upcoming excluded during merge) |
| Entire recurring series cancelled (base schedule archived) | Existing `baseRecurring.archivedAt != null` check already excludes the thread from agenda; activity feed still shows the thread via the non-range path, but `recurring` is true and no instances generate → `rep = null` → no RSVP UI |

## Testing

### Unit tests (Dart, `apps/plot/test/store/`)

For a test Thread harness with pre-seeded schedule data:

1. **Non-recurring, future event** → representative is base, `isLinkScheduleInstance=true`, `rsvpInheritedFromSeries=false`.
2. **Recurring, upcoming instances** → representative is the earliest future instance; `occurrence` is set.
3. **Recurring, only past instances** → representative is the latest past instance.
4. **Recurring, no instances in window** → `null`.
5. **Recurring, past upcoming override archived** → representative is the latest past, archived upcoming excluded.
6. **Recurring, series-skipped** → representative carries `currentUserRsvp='skip'`, `rsvpInheritedFromSeries=true`.
7. **Recurring, occurrence-level override with user schedule_contact** → representative for that occurrence carries `rsvpInheritedFromSeries=false`.
8. **Non-calendar thread (no link schedule)** → `null`.
9. **Todo base (todo && !isLinkScheduleInstance)** → `null`.

### Widget tests (`apps/plot/test/widget/`)

For the activity-feed `ThreadWidget`:

1. Recurring event, no RSVP yet, has attendees → Attend + Skip visible; schedule-date header shows the next upcoming occurrence.
2. Recurring event, series-declined → ToggleRsvp visible, label "Attend"; tapping it posts `{thread_id, status: 'attend'}` with no `occurrence`.
3. Recurring event, occurrence-level attend → ToggleRsvp visible, label "Skip"; tapping posts with `occurrence`.
4. No-link-schedule thread → no RSVP UI (`showEventTiming: false`).

### Integration

Agenda tests for existing RSVP paths continue to pass unchanged — the `rsvpInheritedFromSeries` default for agenda-materialized threads is false, matching the current semantics.

## Migration / rollout

No schema, no server, no data migration. Client-only change, shippable in a standard Flutter release.

## Out-of-scope follow-ups

- **Dynamic window.** ±60d is a reasonable default for "events that show up in the feed". If users regularly see stale recurring threads whose last instance was >60 days ago and no upcoming instances land in the next 60 days, we could widen the window per-thread or extend to "latest persisted override" as a fallback. Not doing it now; easy to add if it comes up.
- **Attendee count indicator.** The layout doc already supports schedule-date metadata. Adding a "N attendees" badge near the title is out of scope — the existing RSVP buttons already communicate that there are other attendees when Attend/Skip is visible.
- **Feed sort side effects.** Representative-occurrence resolution is render-only and does NOT feed back into the activity feed's sort key (which uses thread activity time, not schedule time). If future work wants "next upcoming event bubbles up in the feed", that's a separate change to the sort logic.
