# Email digest: only notify on unseen Plot-authored content

**Date:** 2026-06-05
**Status:** Design — approved pending spec review

## Problem

Plot sends a digest email to users who haven't been active in the app, listing
their unread threads. The current mechanism does **not** distinguish between:

- **Plot-only threads** — created in Plot and only available in Plot.
- **Connector-synced threads** — items that came from external systems (Gmail,
  Google Calendar, Linear, Slack, …) via a connector.

As a result, users receive email notifications about content that originated in
external systems, where they already get notified by the source system. We want
the digest to cover **only genuine Plot activity**: a new note that was written
in Plot and that the user hasn't seen.

## Requirements

1. **Never include connector-synced threads** in the digest.
2. **Only send** when there is a legitimate new note authored in Plot that the
   user hasn't seen. If a user's only unread activity is connector-synced, no
   email is sent.

## Relevant data model

- `thread.twist_id` — `NULL` ⇒ created in Plot; `NOT NULL` ⇒ the thread's dedup
  is owned by a connector/source twist (`twist.is_source = true`), i.e. it came
  from an external system. This is the canonical "connector-synced thread"
  signal.
- `note.link_id` — `NULL` ⇒ note authored in Plot; `NOT NULL` ⇒ note synced
  through a connector link. On a Plot-only thread, all notes are `link_id IS NULL`.
- `note.author_id` — the **contact** (or twist) credited for the note, i.e. who
  authored it for display. A twist writing on a user's behalf sets
  `author_id` to the user's contact while `created_by` is the twist instance —
  so author attribution is the correct signal for "did the user write this."
- `"user".user_contact_ids(user_id)` — returns the array of every contact linked
  to the user. Already used by the digest query for visibility (`t.contacts &&
  …`). `STABLE`, so it is evaluated once per query.
- **Read state is thread-level only.** `thread_state.read_at IS NULL` means the
  user hasn't seen the thread; there is no per-note seen tracking. The
  `update_thread_on_note_change()` trigger keeps a note author's own `read_at`
  set, so a user's own notes do not make a thread unread for them.

## Approach

A **query-only** change, contained entirely to the unread-threads query in
`EmailNotify.alarm()` (`workers/api/src/state/email-notify.ts`). No schema
changes, no trigger changes, no change to what schedules the alarm.

Rationale for not touching the trigger: connector activity may still *schedule*
the 18-hour email alarm via `PushNotify`, but with the filtered query the alarm
resolves to "no eligible threads → skip" — a harmless no-op. Gating the trigger
as well would couple push and email logic for no user-visible benefit.

### The change

Add two clauses to the existing `WHERE` of the digest query
(`email-notify.ts:142-164`):

```sql
-- 1. Exclude connector-synced threads (keep only Plot-created threads).
AND t.twist_id IS NULL

-- 2. Require a genuine unseen Plot-authored note (the send gate).
AND EXISTS (
  SELECT 1 FROM note n
  WHERE n.thread_id = t.id
    AND n.link_id IS NULL                                            -- authored in Plot, not connector-synced
    AND n.archived_at IS NULL
    AND NOT (n.author_id = ANY("user".user_contact_ids(tu.user_id))) -- a note the user didn't author
)
```

The final query keeps all existing clauses (unread, importance/urgent, not
archived, draft ownership, contacts/groups visibility) and adds the two above.

### Why both clauses

- Clause 1 is the primary filter and directly satisfies Requirement 1.
- Clause 2 directly enforces Requirement 2 and is defensive against edges that
  clause 1 alone doesn't cover:
  - An unread thread whose unread state was set by a non-note `thread_state`
    mutation (importance/order/etc.) with no real new note.
  - A non-source twist posting a *link-backed* note onto a Plot thread.
  - A thread whose only Plot notes are authored by the user's own contacts
    (including a twist acting on their behalf) — already seen, so no email.

  On a typical Plot-only thread with another person's note, clause 2 is
  satisfied; on a Plot-only thread with only the user's own notes it is not.

### Unchanged behavior

- The "no rows → skip" early-out and the `lastEmailedUnreadAt` vs latest
  `thread_updated_at` dedup now operate over the filtered set, so an email is
  sent only when the *filtered* set has new activity.
- Error handling is unchanged: the query runs inside the existing `withDb` +
  try/catch with `captureException`.

## Testing

Extend unit coverage for `alarm()` to assert:

1. A connector-synced thread (`thread.twist_id` set) is excluded from the digest.
2. A Plot-only thread with another user's Plot note (`link_id IS NULL`,
   `author_id` not in the recipient's contacts) **is** included.
3. A Plot-only thread whose only notes are connector-synced (`link_id` set) does
   **not** trigger a send.
4. A Plot-only thread whose only notes are authored by the recipient's own
   contacts does **not** trigger a send.
5. A user whose only unread activity is connector-synced receives **no** email
   (no rows → skip).

The exact harness (existing DO test setup vs. a focused query test) will be
confirmed when writing the implementation plan.

## Out of scope

- Trigger-side changes (what schedules the 18h alarm).
- Per-note "seen" tracking / any schema change.
- The in-app push notification path (this spec covers the email digest only).
