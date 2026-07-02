# Scheduled sending & send windows — design

**Date:** 2026-07-01
**Status:** Approved design, amended 2026-07-01 after pre-implementation code review
(thread-level hold via `thread.send_at`, null-`send_at` release claim, `POST /sync/notes`
hold gates, "[verb] [time]" send-button affordance)
**Author:** Kris + Claude (brainstormed)

## 1. Overview

Two related features, both built on a single new note field:

1. **Scheduled sending** — a clock control beside the Send button lets the user pick a
   date + time (to the minute) for a message to be sent. The message is authored
   immediately but held by the **server** until its scheduled instant, so it sends at the
   right time even if the app is offline. Works for notes that create new threads and
   for replies, in every thread type including connector-backed ones (Gmail, Slack,
   LinkedIn, …). Connectors remain unaware of a scheduled note until it is released.

2. **Send windows for focuses** — a per-focus setting (with defaults cascading from
   roles, exactly like existing notification settings) defines recurring windows of time
   during which messages may go out. When a message is drafted **outside** a window, it
   is auto-scheduled to the next window opening. The user can change or clear that.

Both features are driven by one concept: **`note.send_at`** — "the server should send
this note at this instant." `NULL` = send immediately (today's behavior). A note whose
`send_at` is set is **held**: visible to its author as *"Scheduled for …"*, invisible to
everyone else and to every connector, until a server sweep releases it. When the
scheduled note *creates a new thread*, the thread row carries a mirrored
**`thread.send_at`** (§3.1b) so the thread shell (title/preview) is also invisible to
recipients until release; the sweep clears both together.

Feature 2 is purely a way of *computing a default* `send_at`. The delivery mechanism is
identical for both.

### Goals

- Server-owned delayed delivery that survives the app being offline.
- Reuse existing patterns wherever possible (undo-send footer, draft/archived hold
  guards, the `notify_window` role→focus cascade, the `FormScheduler`/`FormWindowList`
  form items).
- Fully keyboard-navigable modal.
- No connector/SDK changes — connectors only ever see released notes, through the
  existing dispatch path.

### Non-goals

- Second-level precision (minute granularity only).
- Editing the *content* of a note in-place while it is scheduled (clicking it pulls it
  back into the composer first).
- Recurring/repeating scheduled sends.
- Timezone selection UI — windows use the device's local timezone.

## 2. Terminology

- **Focus** = a `priority` (code/DB). Flutter `Priority`, table `priority`.
- **Role** = a flat grouping of focuses carrying default settings its focuses "follow".
  Flutter `Role`, table `role`. Every focus has `role_id`.
- **Send window** = a recurring time-of-day range, per weekday, during which messages
  may be sent. Stored as a list of `{days,start,end}` objects (the existing
  `AttentionWindow` shape).
- **Held note** = a note with `send_at IS NOT NULL` (not yet released) — withheld from
  recipients and connectors. A new thread composed with a held first note is likewise a
  **held thread** (`thread.send_at IS NOT NULL`).
- **Release** = the server sweep atomically **nulling `send_at`** (note, and thread if
  set) at/after the scheduled instant — this is both the go-live flip and the
  idempotency/claim marker (§5.2).

## 3. Data model

### 3.1 `note.send_at` (Feature 1)

A single nullable timestamp on the note, synced through the **normal** note sync path
(`/sync/notes` + `upsert_note` RPC) — it is a note field, not a settings cascade.

**Postgres** (`libs/db/schema/50-tables/25-note.sql`):

- Add `send_at timestamptz` (nullable). Minute precision (seconds always `00`; the client
  truncates, no server enforcement needed).
- Follow the schema-change workflow in the root `AGENTS.md` ("Database Schema Changes"):
  edit schema files → `pnpm gen-migration -- add_note_send_at` → `pnpm apply-migrations`
  → commit regenerated `libs/db/src/types.ts`.

**Flutter Drift** (`apps/plot/lib/store/note.dart`, `Notes` table ~lines 100–119):

- Add `DateTimeColumn get sendAt => dateTime().nullable().map(const LocalDateTimeConverter())();`
  (match the `sourceCreatedAt` converter usage).
- Thread `sendAt` through `Note` ctor (~197–244), `Note.draft` (~246–264), `copyWith`,
  and **explicitly** through `NotesBase.fromBase`/`toBase` (~121–195) as
  `send_at` (ISO string ↔ DateTime) rather than relying on JSON passthrough.
- Migration: add `if (from < 377) { await m.addColumn(notes, notes.sendAt); }` in
  `Store.migration.onUpgrade`, bump `Store.schemaVersion` 376 → 377
  (`apps/plot/lib/store/store.dart:2728`), run `flutter pub run build_runner build`.

Naming rationale: `send_at`/`sendAt` (not `scheduled_at`) to distinguish from the thread
**agenda** schedule (`thread.at`/`on`, the `schedule` table).

### 3.1b `thread.send_at` (Feature 1 — new-thread compose)

Without a thread-level hold, a scheduled note that *creates a new thread* leaks the
thread shell: the thread row must push non-draft immediately (the client push filter
excludes `draft = 1` threads AND any note whose parent thread is a local draft,
`store.dart` `_buildDraftFilter`), and `user.thread` exposes `title`/`preview` to every
contact-visible user with no dependence on live notes — so a Plot-user recipient (also
true for a scheduled Gmail compose to a colleague on Plot) would see the shell for the
entire delay. The hold is therefore mirrored on the thread:

- **Postgres** (`libs/db/schema/50-tables/24-thread.sql`): add `send_at timestamptz`
  (nullable), same semantics as `note.send_at`. Add `p_send_at` handling to
  `upsert_thread` (`libs/db/schema/90-user-schema/80-upsert_thread.sql`).
- **Visibility guard** (`libs/db/schema/90-user-schema/30-thread.sql`, `user.thread`):
  add `AND (a.send_at IS NULL OR a.send_at <= now() OR a.created_by = tp.user_id)` so a
  held thread is visible only to its author. (`user.thread_redacted` is unaffected —
  revocation is orthogonal.) `/sync/threads/search` needs the same guard for non-authors.
- **Flutter Drift** (`apps/plot/lib/store/thread.dart`): add `sendAt` column +
  `fromBase`/`toBase` mapping + migration (same 376 → 377 bump as §3.1).
- The client sets `thread.sendAt = note.sendAt` when promoting a scheduled new-thread
  compose (§4.3); replies never set it. The release sweep clears both together (§5.2).

Why not reuse `draft`/`archived_at` for the hold (considered, rejected): an archived
thread hides from the **author's** feed too (`COALESCE(a.archived_at, tp.archived_at,
…)` in `user.thread`), and a `draft = 1` thread never reaches the server (push filter) —
loosening that filter conditionally would weaken the core don't-push-drafts safety net,
and the local UI treats draft threads as compose-in-progress.

### 3.2 `send_window` on `role` and `priority` (Feature 2)

A near-verbatim clone of the existing `notify_window` setting. Value type: a JSON list of
`AttentionWindow` (`apps/plot/lib/store/attention.dart`, `{days:[ISO 1-7], start:"HH:MM",
end:"HH:MM"}`). `NULL`/empty = no send window (send anytime). The cascade is
**denormalized via server triggers** (both role and focus store concrete values; the
role's value is the default and a trigger fans role changes out to focuses that still
match) — *not* resolved at read time.

Clone every touch-point of `notify_window`:

**Postgres:**
- `libs/db/schema/50-tables/21-role.sql` — add `send_window jsonb` (beside
  `notify_window`, ~lines 20–23).
- `libs/db/schema/50-tables/22-priority.sql` — add `send_window jsonb` (~lines 58–61).
- `libs/db/schema/95-triggers/30-role-propagation.sql` — add `send_window` to **both**
  `propagate_role_to_focuses()` (~15–46) and `apply_role_change_to_focus()` (~55–118),
  matching the follow-if-matching logic used for the notification columns.
- `libs/db/schema/90-user-schema/22-priority.sql` — expose `send_window` and a derived
  `(p.send_window IS NOT NULL) AS send_window_set` in the `user.priority` view
  (~88–98).
- `libs/db/schema/90-user-schema/24-role.sql` — expose `send_window` in `user.role`
  (~12–14).
- `libs/db/schema/90-user-schema/85-user-sync-upserts.sql` — add
  `p_send_window`/`p_set_send_window` params to `upsert_priority_attention`, using the
  same `COALESCE(p_value, (SELECT r.send_window FROM role r WHERE r.id = p.role_id))`
  follow-the-role fallback.
- `libs/db/schema/90-user-schema/25-upsert_role.sql` — add `send_window` to `upsert_role`
  (INSERT + `ON CONFLICT` `CASE WHEN p_role ? 'send_window'` + the Inbox seed copy).

**Flutter Drift:**
- `apps/plot/lib/store/priority.dart` — add `sendWindow` `TextColumn` + `sendWindowSet`;
  add jsonb↔TEXT in `PrioritiesBase.fromBase` (~112–123); **strip** `send_window` from
  `PrioritiesBase.toBase` (~162–178) because it is written via `/sync/priority-attention`,
  not the generic push; add a `sendWindows` parse getter (mirror `notifyWindows` ~1317);
  thread through `copyWith` (~1396–1454).
- `apps/plot/lib/store/role.dart` — add `sendWindow` `TextColumn`, jsonb↔TEXT in
  `RolesBase.fromBase`/`toBase` (~44–72), a `sendWindows` getter (~200), and ensure the
  warm `Role.cache` carries it (~134–194).
- Migration: `if (from < 377) { await _safeAddColumn(m, priorities, priorities.sendWindow);
  await _safeAddColumn(m, roles, roles.sendWindow); }` (same schema bump as §3.1).

> Feature 1 (`send_at`) and Feature 2 (`send_window`) share the **same** Drift
> `schemaVersion` bump (376 → 377) and the **same** Postgres migration batch.

## 4. Feature 1 — manual scheduled sending

### 4.1 Clock control & modal

**Placement.** The clock icon sits **directly left of the primary Send/Post/Save button,
grouped on the right** — i.e. after the `const Spacer()`, immediately before the primary
`Button` in both `_buildNoteBottomBar` (`apps/plot/lib/widget/note_editor.dart`
~1505–1595, button ~1562–1590, spacer ~1558) and `_buildNewThreadBottomBar` (~1597–1673).
It is **not** in the left-aligned to-do/link/attach cluster (~1519–1557).

- Hidden entirely in **note-edit** mode (`_isEditing` / "Save changes") — scheduling is
  for new sends only.
- Inactive state: outline/ghost clock icon, tooltip **"Schedule send"**.
- Active state (draft has `sendAt`): filled/accent clock icon, tooltip shows the absolute
  scheduled time, e.g. **"Scheduled for Mon, Jul 7, 9:00 AM"** (`send_at.toLocal()` via
  `time.dart` `format('EEE, MMM d, h:mm a')`).
- **Primary button when scheduled (confirmed decision):** wherever the send verb renders
  (label or tooltip — `_sendLabelForState`, `note_editor.dart` ~1182–1204), it becomes
  **"[verb] [time]"** with the context-appropriate verb, e.g. "Send Mon, Jul 7, 9:00 AM"
  / "Post tomorrow 9:00 AM". This makes a silently auto-scheduled draft (§6.2)
  unmissable at the point of action.

**Modal.** Clicking opens a **"Schedule send"** modal. Reuse the modal framework
(`apps/plot/lib/widget/modal.dart` → `FormModal`) and the existing date/time form item
**`FormScheduler`** (`apps/plot/lib/widget/form_scheduler.dart`) — the AGENTS.md-blessed
example of a keyboard-navigable date/time `FormItem` with cursor-key stepping. This gives
Tab/↑/↓/Enter/Esc navigation for free; do **not** hand-roll a raw `Modal`.

Modal contents:
- A date field and a time field (minute granularity, **no seconds**), initialized per
  §4.2.
- Primary action **"Schedule"** — sets the draft's `sendAt` (seconds zeroed), activates
  the clock icon, updates the remembered default (§4.2), dismisses. Bound to Enter.
- **"Clear schedule"** — shown only when `sendAt` is currently set; clears it (revert to
  immediate send), dismisses.
- Esc dismisses without change.

Copy is sentence-case per project convention.

### 4.2 The default time & the remembered default

A **user-scoped local preference** stores the last manually-chosen offset as
`{dayOffset:int, time:"HH:MM"}`. Store it via the user-scoped preferences registry (the
one added in the sign-out state-leak fix) so it is cleared on sign-out. Not synced across
devices (acceptable; can be promoted to a synced pref later).

**Initial value shown when the modal opens:**

```
pickerInitial(draft, remembered, now):
  if draft.sendAt != null:            # already scheduled (manual re-open, or auto-scheduled)
      return draft.sendAt
  return rememberedDefault(remembered, now)

rememberedDefault(remembered, now):
  if remembered == null:
      return tomorrow9(now)
  candidate = date(now) + remembered.dayOffset days, at remembered.time   # local tz
  if candidate <= now:                # the remembered slot has passed today
      return tomorrow9(now)
  return candidate

tomorrow9(now): (date(now) + 1 day) at 09:00 local
```

**On "Schedule" with chosen instant `t`:**

```
draft.sendAt = t with seconds = 0
remembered   = { dayOffset: calendarDaysBetween(date(now), date(t)),
                 time: "HH:MM" of t }
```

This yields the behavior in the spec: choose 2 PM today → next open defaults to 2 PM
today, unless that has passed, in which case it reverts to 9 AM tomorrow.

> **Key precedence rule (confirmed):** "next window opening" (§5) is produced **only** by
> the outside-window auto-schedule. The manual picker's fallback is **always** the
> remembered time (else tomorrow 9 AM) — even when a send window is configured and the
> user is currently inside it.

### 4.3 Send flow (client)

Assembly happens at the single existing choke point `_finalizeNoteDraft`
(`note_editor.dart` ~1880–1971): carry `sendAt` onto the finalized note via `copyWith`.
Same for `finalizeThreadDraft` (~2004–2086) for new threads.

`ThreadBloc.sendWithUndo` (`apps/plot/lib/state/thread.dart` ~336–391) and
`PriorityBloc.sendThreadWithUndo` (`apps/plot/lib/state/priority.dart` ~4064–4101) branch
on `note.sendAt`:

- **`sendAt != null` (scheduled):** **skip the 5-second `PendingSend` undo window**
  entirely. Save the note `draft = false` + `send_at` and push immediately
  (`save(pushToRemote: true)`). The note must be non-draft so it passes the client push
  claim (`_buildDraftFilter` appends `draft = 0`, `store.dart` ~1490–1524) and reaches the
  server; the server then holds delivery via §5. Promote a still-draft thread as today
  (so nothing strands), **setting `thread.sendAt = note.sendAt` on it** (§3.1b) so the
  thread shell is held server-side alongside the note. The Scheduled footer state (§4.4)
  *is* the "undo".
- **`sendAt == null`:** unchanged undo-send behavior (`PendingSend`, 5 s).

`AddNote` command entry (`apps/plot/lib/command/note.dart` ~20–63) is unchanged (it calls
`sendWithUndo`).

The scheduled note's **display/sort timestamp** uses `send_at` as its `sourceCreatedAt`,
so it sorts to the bottom of the thread ("the next thing to send") and, after release,
reads with the intended send time. Connector write-back may overwrite the source time on
delivery as it does today.

### 4.4 Scheduled note state (footer)

Reuse the undo-send ghost-button pattern in `apps/plot/lib/widget/note.dart` (footer Stack
~250–432; the `sending ✕` ghost button ~333–395). Add a **scheduled** state, computed as
`note.sendAt != null && note.sendAt!.isAfter(Time.now())`:

- Right slot renders **"Scheduled for [relative date] [time]"** instead of
  author/timestamp, using `formatRelativeSchedule` (`apps/plot/lib/util/time.dart` ~828+)
  — e.g. "Scheduled for Tomorrow, 9:00 AM". Include a small clock glyph. Make the whole
  label tappable.
- Left slot keeps `NoteCommands` as in the sending state (~400–429).
- Because a scheduled note is a real `draft=false` row, it appears in the author's own
  thread/list/feed/search immediately (consistent with undo-send "real locally"); the
  server view (§5) keeps it hidden from everyone else.

Wiring in `apps/plot/lib/page/thread.dart`: the note list already rebuilds via a
`ListenableBuilder` for `PendingSend` (~852–876); the scheduled state instead derives from
the note row itself (a stream/Bloc rebuild when `send_at` changes), so no global listenable
is needed. `_buildItemAtIndex` (~927–939) passes a `scheduled`/`onEditScheduled` pair to
`NoteWidget` alongside the existing `sending`/`onUndoSend`.

### 4.5 Editing / rescheduling / deleting a scheduled note

Tapping the scheduled footer must **immediately unschedule** (so an offline schedule can
never fire after the user pulls it back) and pull the content into the composer:

1. **Cancel the server-side send by archiving the scheduled note**: `copyWith(archivedAt:
   Value(now)).save(pushToRemote: true)` — **leave `send_at` unchanged (still future)**.
   Archiving (not draft-flag) is used because archived non-draft rows still push (only
   `draft = 1` is filtered out), so the cancellation reliably reaches the server, where
   `archived_at IS NULL` already excludes it from all dispatch (§5). **Do not null
   `send_at` here:** `send_at = NULL` means "send immediately", so if the archive write
   were lost but a null-`send_at` write applied, the note would fire instantly — the exact
   failure this feature guards against. Keeping `send_at` in the future makes the note
   fail *closed* (still held) if the archive somehow doesn't stick. The held note was
   never delivered, so discarding it is safe; the release sweep skips archived rows (§5.2).
2. **Restore content into a fresh draft** (mirror `ThreadBloc.restoreDraft` ~395–411):
   content, actions, mentions, and the **prior `sendAt`** pre-filled so the clock shows
   active and re-scheduling is one click. Re-entering reply mode / composer focus at end
   (`focusAtEnd`).

From the composer the user can then:
- **Reschedule** — pick a new time and Send → a **new** scheduled note (new id; safe,
  since nothing was ever delivered).
- **Send now** — Clear schedule, then Send → normal immediate send (with the 5 s undo).
- **Delete** — discard the draft (existing discard); the archived original is already
  canceled.

**New-thread compose:** when the scheduled note is the composing note of a new thread,
unscheduling archives the **whole thread** (thread + note, `pushToRemote: true`) and
restores a full new-thread draft; re-sending takes the normal compose path with a fresh
thread id. Keeping the old thread would strand it: a later re-send goes through
`POST /sync/notes` (the reply path), which never performs the deferred
`dispatchCreateLink`, so the external item would silently never be created — and the
held thread shell would linger. Archiving both is fail-closed for the same reason as the
note (both `send_at`s stay future; archived rows are excluded from release).

**Release race:** the tappable "Scheduled for …" state derives from
`sendAt.isAfter(now)`, so the pull-back affordance disappears client-side at the
scheduled instant. If the user taps within the same minute the sweep fires, the archive
can arrive after release — the note was already delivered externally and the archive
merely hides the local copy (the same inherent race Gmail's scheduled send has).
Accepted as-is.

## 5. Server-side hold & release

### 5.1 Hold — extend the existing `draft`/`archived_at` guards with `send_at`

Everywhere the server currently treats a note as "not yet live" via `draft`/`archived_at`,
add the guard `AND (n.send_at IS NULL OR n.send_at <= now())`. This is the entire hold —
no note reaches a recipient or connector while `send_at` is future, but the author still
sees it (author rows are keyed on `created_by = user`). (The `<= now()` branch only
matters for the ≤60 s between the instant passing and the sweep claiming the note; after
release `send_at` is NULL, §5.2.)

Sites (all found during exploration; 6–7 confirmed during pre-implementation review):

1. **Visibility** — `libs/db/schema/90-user-schema/31-note.sql`, `user.note` filter
   (~line 48, currently `(n.draft = FALSE OR n.created_by = tp.user_id)`). Extend so a
   held note is visible to its author but no one else.
2. **Reply/mention dispatch qualification** —
   `libs/db/schema/70-views/71-twist-instance-note-create.sql` (~48–56).
3. **Channel (connector-thread) dispatch qualification** —
   `libs/db/schema/70-views/77-twist-instance-channel-note-create.sql` (~56–65).
4. **Thread activity/unread trigger** —
   `libs/db/schema/50-tables/25-note.sql`, `update_thread_on_note_change` guard (~line
   182) — so a held note does not surface the thread or mark it unread for recipients.
5. **Compose create-link gate (new connector thread, Path B)** —
   `workers/api/src/app/sync/threads.ts` (~line 1121, `threadData.draft !== true`
   waitUntil that calls `dispatchCreateLink`). Skip the in-request `dispatchCreateLink`
   when the composing note is held, but **still write the `pending_create_link` stash**
   (`thread.pending_create_link`, threads.ts ~1174–1186; column at `24-thread.sql:73`) —
   the release sweep performs the deferred dispatch from that stash (§5.2), rebuilding
   the draft the way `note-retry-send.ts` does.
6. **New-thread shell visibility** — the `thread.send_at` guard on `user.thread` and
   `/sync/threads/search` (§3.1b).
7. **`POST /sync/notes` in-request side effects** — `workers/api/src/app/sync/notes.ts`:
   BOTH the mention-twist `TWIST_SYNC` notify gate (~line 324, currently `!body.draft`)
   and the background AI/unread/notification fan-out gate (~line 359, currently
   `!body.draft && !body.archived_at && !isUpdate`) must also skip held notes — otherwise
   recipients are marked unread and push-notified at *schedule* time. The release sweep
   replays both at release (§5.2). The thread content search (trigram over non-draft
   notes) must likewise exclude held notes for non-authors.

Because the two dispatch qualification views and the compose gate all exclude held notes,
the actual external-send choke points — `onNoteCreated`
(`workers/api/src/twist/entrypoint.ts` ~776) and `onCreateLink`
(`workers/api/src/app/sync/create-link-dispatch.ts` ~121) — are never reached for a held
note. No connector code changes.

### 5.2 Release — a server-owned cron sweep

New idempotent sweep `workers/api/src/scheduled/publish-scheduled-notes.ts`, invoked from
`workers/api/src/index.ts` `scheduled()` (~288), matching the shape of existing sweeps
like `finalizeEventSessions` (~398). Each tick:

1. **Claim by atomically nulling `send_at`** — the release marker (confirmed decision;
   without one, a released note would match "held + past due" forever and re-publish
   every tick):

   ```sql
   UPDATE note SET send_at = NULL
   WHERE send_at IS NOT NULL AND send_at <= now()
     AND draft = FALSE AND archived_at IS NULL
   RETURNING id, thread_id, ...;   -- bounded batch per tick
   ```

   `send_at IS NOT NULL` in the predicate is the idempotency: a claimed note can never
   be re-selected. The UPDATE bumps `seq` via the existing `set_note_updated_at`
   trigger, so clients resync the note to its sent state and `TwistSync` re-qualifies
   it. In the same transaction, null the parent `thread.send_at` where set — releasing
   the held thread shell (§3.1b) and re-emitting the thread to recipients.

2. **Fire the activity/unread trigger at release.**
   `update_thread_last_note_created_at_on_status_change` currently fires only on
   `UPDATE OF draft, archived_at, source_created_at` (`25-note.sql` ~291–299) — a bare
   seq-touch would NOT re-fire it and recipients would never get the thread
   surfaced/unread. Add `send_at` to its `UPDATE OF` column list and `WHEN` clause
   (alongside the §5.1 hold guard inside `update_thread_on_note_change`). The claiming
   UPDATE (`send_at` future → NULL) then fires it naturally: the thread surfaces and
   recipients get thread_state/unread bumps keyed on `source_created_at` (= the intended
   send time), all through the existing trigger.

3. **Dispatch** each claimed note (post-claim, best-effort — the qualifying views retain
   the note until processed):
   - **Reply / mention notes:** wake the note's twist targets' `TWIST_SYNC` DO `/notify`
     (the same call `POST /sync/notes` makes for non-draft notes, `notes.ts` ~324–352).
     `TwistSync.alarm()` (`workers/api/src/state/twist-sync.ts` ~354–412) then polls the
     now-qualifying dispatch views → `UPDATES_QUEUE` → `processTwistBatch`
     (`workers/api/src/queue/updates.ts`) → `onNoteCreated`.
   - **New connector thread (compose):** perform the deferred `dispatchCreateLink`
     (`create-link-dispatch.ts` ~121) from the `pending_create_link` stash written at
     compose time (§5.1(5)), rebuilding the draft the way `note-retry-send.ts` does.
   - Fire the same background fan-out `POST /sync/notes` runs for a fresh non-draft note
     (embeddings, AI analysis, unread/notification fan-out — `notes.ts` waitUntil
     ~359–360), so recipients get notified at release time.
4. Use the fresh-connection discipline (`createDb`/`destroy` in `finally`). If the
   isolate dies between claim and dispatch, the note is already live and view-qualified;
   the next `TwistSync` wake for that twist picks it up — the same loss class as today's
   in-request `waitUntil` dispatches.

Follow the "Never `DELETE`/never ignore DB errors / `captureException` on unexpected
failures" rules from AGENTS.md.

### 5.3 Precision

Add a dedicated **1-minute cron** so release latency is ≤ 60 s:

- `workers/api/wrangler.jsonc` (~360 / 669) — add `"* * * * *"` to `crons`.
- In `scheduled()`, branch on `controller.cron`: when it is the 1-minute schedule, run
  **only** `publishScheduledNotes()`; the existing `*/5 * * * *` work is untouched.

(Exact-second precision via a `CallbacksState` DO alarm — `workers/api/src/state/callbacks.ts`,
armed at the earliest `send_at` — is possible as a later upgrade but adds per-note DO
state; the 1-minute cron satisfies the offline-proof requirement and matches every
existing durable-timing pattern.)

### 5.4 Offline authoring past `send_at`

If the device is offline past `send_at`, the held note sits locally with `pending` set and
pushes when connectivity returns; the server then sees `send_at` already in the past →
the next sweep releases it immediately. Acceptable best-effort behavior. Locally the
footer keeps showing "Scheduled for …" until the row syncs back with `send_at` nulled by
the sweep.

## 6. Feature 2 — send windows (client resolution)

### 6.1 Which focus governs

Resolve the send window from the **thread's own focus**, never the viewing context:

- **New thread:** the focus selected as the compose target for the new thread.
- **Existing thread (reply):** the thread's focus (`thread.priority` — its primary/home
  priority, as used by `FocusLabel`).

Resolve the focus's effective `sendWindow` from its denormalized Drift column
(`priority.sendWindow`), which already carries the role default via the server cascade.

### 6.2 Auto-schedule computation

When a draft is being composed for an **outward** note (shared or connector-backed —
private/unshared notes are exempt, mirroring the undo-send `immediate = note.isPrivate ||
!thread.isShared` logic), evaluate at composer-open and whenever the target focus or
recipients change:

```
maybeAutoSchedule(focus, note, now):
  if note is private / not shared:        return   # exempt
  windows = focus.sendWindows              # from priority.sendWindow (role-cascaded)
  if windows is empty:                     return   # no window → immediate
  if insideAnyWindow(windows, now):        return   # inside → immediate, clock inactive
  if note.sendAt != null:                  return   # user already chose a time — don't override
  if draft.userTouchedSchedule:            return   # user scheduled OR cleared manually — sticky
  note.sendAt = nextWindowOpening(windows, now)     # outside → auto-schedule; clock active

insideAnyWindow(windows, now):
  weekday = ISO weekday of now (1-7)
  return any w in windows where weekday in w.days and w.start <= timeOfDay(now) < w.end

nextWindowOpening(windows, now):
  # scan forward up to 7 days; earliest opening strictly after now
  for d in 0..7:
    day = date(now) + d
    for w in windows where ISOweekday(day) in w.days:
      opening = day at w.start (local tz)
      if opening > now: candidates.add(opening)
  return min(candidates)
```

Notes:
- Windows are **same-day** (`start < end`, no cross-midnight), matching the
  `notify_window`/`AttentionWindow` assumption.
- Windows are interpreted in the **device local timezone**; `nextWindowOpening` produces
  an absolute instant stored in `send_at`, so DST/travel are fixed at draft time.
- Auto-schedule sets `send_at` on the **local draft** only (drafts aren't pushed); it
  materializes server-side on Send, when the note becomes `draft=false` + `send_at`.
- The user can always open the clock modal to change the time or Clear schedule; a manual
  choice takes precedence (`sendAt != null` short-circuits re-computation).
- **Clearing is sticky for the draft's lifetime**: the composer tracks a
  `userTouchedSchedule` flag once the user schedules *or* clears via the modal, and
  `maybeAutoSchedule` short-circuits on it — otherwise a recipient/focus change after an
  explicit clear would silently re-auto-schedule (`sendAt == null` alone can't tell
  "never scheduled" from "user cleared").

### 6.3 Settings UI (cascade, clone of notifications)

- **Per-focus editor** — add a "Send window" field to the form in
  `apps/plot/lib/command/early_notifications.dart` (the `ShowForm` at ~84, form
  ~195–314), reusing **`FormWindowList`** (`apps/plot/lib/widget/form.dart` ~1110). Mirror
  `_resolveInherited` (~316–345) for the parent-focus fallback and the save logic
  (~444–557): when the focus's value equals the inherited/role value, send `null` +
  `set_send_window: true` to clear the override; POST `/sync/priority-attention`
  (`workers/api/src/app/sync/priority-attention.ts` ~21–42), then `Priority.pull()`.
  Consider whether "Send window" belongs on the existing notifications form or its own
  focus-menu entry — recommend its own entry (`ShowSendWindowSettings`) so notifications
  and send windows stay conceptually distinct; wire it into the focus "…" menu near
  `command/priority.dart:1689`.
- **Per-role editor (the default)** — add the field to
  `apps/plot/lib/command/role_notifications.dart` (or a sibling `ShowRoleSendWindowSettings`)
  writing the absolute value onto the role via `role.copyWith(sendWindow: …).save()`
  (~355–386), relying on the server `propagate_role_to_focuses` trigger to fan out; wire
  near `command/role.dart:178`.

Empty/no window (the default state) = send anytime; existing behavior is unchanged for
users who never configure a window.

## 7. Sync & backwards compatibility

- `send_at` (note **and** thread) and `send_window` are **additive nullable** fields →
  old clients ignore them. Old clients never set `thread.send_at` (their composes stay
  immediate) and never see other users' held threads (server view guard).
- An **old client** receiving a note with future `send_at` shows it as a normal note; but
  the server `user.note` view already hides it from non-authors, and for the author it is
  their own note (harmless slightly-wrong footer). No data corruption.
- New client ↔ old server: never occurs (server ships first); still, absence of `send_at`
  = immediate, the safe default.
- **No public submodule / Twister SDK changes** — connectors only ever receive released
  notes via the existing `onNoteCreated`/`onCreateLink` path. (Finalize checklist item 5:
  none.)
- Regenerate and commit `libs/db/src/types.ts` with the migration (`db:lint` CI gate).

## 8. Edge cases

- **Scheduling a private note:** allowed via the manual clock (a deferred note-to-self);
  send windows do **not** auto-schedule private notes.
- **Note-edit mode:** clock hidden; edits are immediate.
- **At-release send failure** (e.g. connector auth broken): reuse the existing
  `delivery_error` "Failed to send" surface (`markSendFailed`
  `workers/api/src/twist/entrypoint.ts` ~820–832; retry via
  `workers/api/src/app/sync/note-retry-send.ts`).
- **Multiple scheduled notes in one thread:** each independent; each releases at its own
  `send_at`. Ordering is by `send_at`.
- **Inbound connector activity while a reply is scheduled:** the scheduled reply still
  goes at its time; no special handling.
- **Composer left open across a window boundary:** `send_at` computed at open may become
  stale; the user sees the clock state and can adjust. Not recomputed continuously.
- **Thread-level activity ordering for the author:** resolved by the trigger guards —
  server-side, a held note never bumps `activity_base`/`thread_state` (INSERT-time guard),
  and the release-time UPDATE bumps them keyed on `source_created_at` (= the send time).
  So the thread sorts at its send time for everyone, from release onward; before release
  the author's thread simply doesn't move on account of the held note. No special-casing
  needed.

## 9. Testing

- **Pure/unit (Flutter):** `rememberedDefault`/`pickerInitial`, `insideAnyWindow`,
  `nextWindowOpening`, and the scheduled-footer state predicate — extract as pure
  functions (`@visibleForTesting`) following the `shouldResetComposerOnDraftChange` /
  `isSubstantiveDraftFields` precedent, since SuperEditor/Bloc block widget-level e2e.
- **Store/migration (Flutter):** `send_at` round-trips through `NotesBase.fromBase/toBase`;
  archiving a scheduled note pushes (not filtered) while a plain draft does not.
- **Server (vitest, `workers/api`):** the hold guards exclude a future-`send_at` note from
  `user.note` (non-author), from both dispatch views, from the compose gate, and from the
  `POST /sync/notes` in-request side effects (§5.1(7)); a held **thread** is invisible to
  non-authors in `user.thread` but visible to its author; the release sweep claims via
  the nulling UPDATE (a second tick selects nothing — idempotency), clears
  `thread.send_at` alongside, fires the extended status-change trigger (unread/
  thread_state rows appear at release, not at schedule), and triggers reply dispatch +
  compose `dispatchCreateLink` from `pending_create_link`; timezone/DST correctness of
  `nextWindowOpening`.
- **Schema:** `pnpm diff-schema-migrations` clean; `pnpm --filter @plotday/db run lint`.
- **Run-app verification** (`run-app` skill): schedule a reply, confirm the footer, tap to
  reschedule/clear, verify a connector-backed thread does not deliver early, and confirm a
  send window auto-schedules an out-of-window draft.

## 10. Implementation sequencing (suggested build order)

1. **Schema + sync plumbing for `send_at`** (note + thread DB columns, `upsert_note` +
   `upsert_thread`, `user.note` + `user.thread` + dispatch views + activity trigger
   guards, compose gate + `POST /sync/notes` gates, search guards; Drift columns +
   migration + base mapping). Ship the hold before any UI can create held notes.
2. **Release sweep + 1-minute cron** (claim-by-nulling UPDATE for note + thread, the
   `send_at` extension to the status-change trigger, deferred `dispatchCreateLink` from
   `pending_create_link`, release-time fan-out). Now a held note (created manually via
   SQL/test) is delivered on time.
3. **Client scheduled-send UI** — clock control, "Schedule send" modal (`FormScheduler`),
   remembered default, `sendWithUndo` branch (incl. `thread.sendAt` on new-thread
   compose), "[verb] [time]" send label, scheduled footer, unschedule/restore (incl.
   archive-whole-thread for new-thread compose).
4. **`send_window` setting** — DB clone of `notify_window` (columns, triggers, upserts,
   views), Drift entities, per-focus + per-role editors.
5. **Auto-schedule resolution** — wire `maybeAutoSchedule` into composer open / focus
   change, using the thread's-focus resolution.

Steps 1–3 deliver Feature 1 end-to-end; 4–5 add Feature 2 on top.

## 11. Documentation & finalization

- `docs/features.md`: note scheduled sending + focus send windows.
- `pnpm updates:new "…"`: a plain-language user-facing bullet (new `### Sending` section
  or similar, per the updates fragment rules).
- Run `/finalize` before committing.

## Appendix — key reference points (as of 2026-07-01 exploration)

**Flutter — compose/send/footer/store**
- `apps/plot/lib/widget/note_editor.dart`: bottom bars ~1505–1595 / 1597–1673, primary
  button ~1562–1590, spacer ~1558, `_onNoteSubmitted` ~1724–1815, `_finalizeNoteDraft`
  ~1880–1971, `finalizeThreadDraft` ~2004–2086, `_sendLabelForState` ~1182–1204.
- `apps/plot/lib/state/thread.dart`: `sendWithUndo` ~336–391, `restoreDraft` ~395–411.
- `apps/plot/lib/state/priority.dart`: `sendThreadWithUndo` ~4064–4101.
- `apps/plot/lib/state/pending_send.dart`: whole file (undo-send hold; scheduled send
  bypasses it).
- `apps/plot/lib/widget/note.dart`: footer Stack ~250–432, ghost button ~333–395,
  `NoteCommands` ~1066–1458, delivery-error banner ~984–1064.
- `apps/plot/lib/page/thread.dart`: `_undoPendingSend` ~199–212, list `ListenableBuilder`
  ~852–876, `_buildItemAtIndex` ~927–939.
- `apps/plot/lib/store/note.dart`: `Notes` table ~100–119, `Note.draft` ~246–264,
  `Note.save` ~897–949, `NotesBase` mapping ~121–195.
- `apps/plot/lib/store/store.dart`: `_buildDraftFilter` ~1490–1524, `_buildHoldFilter`
  ~1475–1488, push claim ~1230–1234, `schemaVersion` 376 at ~2728.
- `apps/plot/lib/util/time.dart`: `formatRelativeSchedule` ~828+, `format` ~89,
  `toTimeAgo` ~716–731.
- `apps/plot/lib/widget/form_scheduler.dart`: `FormScheduler` FormItem (extend for the
  modal). `apps/plot/lib/widget/form.dart`: `FormWindowList` ~1110.
- `apps/plot/lib/store/attention.dart`: `AttentionWindow` ~5–206.

**Flutter — focus/role settings cascade (template)**
- `apps/plot/lib/store/priority.dart`: notify cols + `notifyWindows` ~1317, `fromBase`
  ~112–123, `toBase` strip ~162–178, `copyWith` ~1396–1454.
- `apps/plot/lib/store/role.dart`: cols ~24–31, getters ~200/204, cache ~134–194.
- `apps/plot/lib/command/early_notifications.dart`: form ~195–314, `_resolveInherited`
  ~316–345, save ~444–557.
- `apps/plot/lib/command/role_notifications.dart`: form ~171–281, save ~355–386.
- Menu wiring: `command/priority.dart:1689`, `command/role.dart:178`.

**Server / DB**
- `libs/db/schema/50-tables/25-note.sql`: note table, `update_thread_on_note_change`
  ~175–299 (guard ~182).
- `libs/db/schema/90-user-schema/31-note.sql`: `user.note` filter ~48.
- `libs/db/schema/70-views/71-twist-instance-note-create.sql` ~48–56;
  `.../77-twist-instance-channel-note-create.sql` ~56–65.
- `libs/db/schema/50-tables/21-role.sql` ~20–23; `.../22-priority.sql` ~44–63.
- `libs/db/schema/95-triggers/30-role-propagation.sql`: `propagate_role_to_focuses`
  ~15–46, `apply_role_change_to_focus` ~55–118.
- `libs/db/schema/90-user-schema/22-priority.sql` ~88–98; `.../24-role.sql` ~12–14;
  `.../85-user-sync-upserts.sql` (`upsert_priority_attention`); `.../25-upsert_role.sql`.
- `workers/api/src/app/sync/notes.ts`: GET ~55, POST ~220, `upsert_note` ~290, twist
  notify ~324–352, waitUntil ~359–360.
- `workers/api/src/app/sync/threads.ts`: compose waitUntil ~1136–1200, gate ~1121,
  `dispatchCreateLink` ~1188. `create-link-dispatch.ts` ~121. `note-retry-send.ts`
  ~34/96/155.
- `workers/api/src/state/twist-sync.ts`: `/notify` ~124, `alarm` ~354–412.
- `workers/api/src/queue/updates.ts`: reply ~281–341 (dispatch ~322), channel ~548–698
  (dispatch ~569). `workers/api/src/twist/tools/integrations.ts`: note ~2514–2522,
  channel_note ~2615. `workers/api/src/twist/entrypoint.ts`: `onNoteCreated` ~776,
  `markSendFailed` ~820–832.
- `workers/api/src/index.ts`: `scheduled()` ~288; existing sweeps in
  `workers/api/src/scheduled/*.ts` (`finalizeEventSessions` ~398).
- `workers/api/wrangler.jsonc`: `crons` ~360 / 669.
- `workers/api/src/state/callbacks.ts`: DO alarm primitive (optional precision upgrade).
