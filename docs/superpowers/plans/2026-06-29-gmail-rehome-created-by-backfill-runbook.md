# Google Re-home — `created_by` Backfill Runbook (write-back repair)

_Authored 2026-06-29. Ops runbook to repair Gmail (and Calendar/Tasks) two-way write-back that broke
after the Google composite cutover (2026-06-25, see `2026-06-24-google-composite-cutover-runbook.md`).
This is a **manually-run, one-time prod SQL operation** — like the cutover itself, not an Atlas migration
(it touches prod-specific `twist_instance` rows, must bypass a protective trigger, and would mis-fire if
auto-applied to an environment that never had the legacy connectors)._

## Symptom

Two-way sync of **Gmail starred ↔ Plot to-do (active)** stopped working in both directions. Also affects
read-state write-back and reply dispatch on pre-cutover threads, and Calendar RSVP / Tasks status write-back
(same root cause).

## Root cause

The cutover archived each user's legacy Gmail/Calendar/Tasks `twist_instance` rows and provisioned a new
**combined Google** instance per account — but **never remapped `created_by`** on the threads/links those
legacy instances had created. Convergence-on-resync flips **`link.created_by`** (via `upsert_link`'s
`ON CONFLICT DO UPDATE`) but **cannot flip `thread.created_by`**: the `protect_thread_created_by` trigger
(`libs/db/schema/95-triggers/13-thread_created_by_protection.sql`) silently reverts any `created_by` change
on a non-archived thread (`NEW.created_by := OLD.created_by`). So `thread.created_by` stays pinned to the
now-archived legacy instance forever.

All connector write-back dispatch gates on `created_by = <active connector instance>`:

| Path | Gate | File |
|---|---|---|
| Gmail→Plot star (`setThreadToDo`) | `link.created_by = this.twistInstanceId` | `workers/api/src/twist/tools/integrations.ts:2161-2166` |
| Plot→Gmail star (`onThreadToDo` dispatch) | view joins `thread.created_by = pt.id`; handler re-checks `link.created_by` | `libs/db/schema/70-views/76-twist-instance-thread-schedule.sql:22`, `integrations.ts:2629` |
| read-state (`onThreadRead`) | `thread.created_by` (view) + `link.created_by` (handler) | `…/75-twist-instance-thread-read.sql:22`, `integrations.ts:2721` |

Because `thread.created_by` never flips, **Plot→Gmail (Direction B) is broken for *every* re-homed thread**,
not just dormant ones; **Gmail→Plot (Direction A)** self-heals on a thread's next sync (link-level flip) but
stays broken for dormant threads.

## Scope (prod, measured 2026-06-29, read-only)

| Legacy connector | stale threads | affected users |
|---|---|---|
| Gmail | 8,180 | 9 |
| Google Calendar | 1,814 | 10 |
| Google Tasks | 2 | 2 |

Exactly **one active combined instance per (owner, Google account)** — confirmed, so a stale thread maps to a
single target once its account is known. 11 of 16 account-instances are still `needs_reauth` (account not yet
reconnected); remapping to them is still correct (write-back gracefully no-ops until reconnect, then resumes).

### Account attribution + coverage

A re-homed thread carries no stored pointer to its Google account (the archived creator instance lost its
connection row; `link.channel_id` is just `INBOX`/`STARRED`/`IMPORTANT`, identical across accounts). The only
reliable signal is **`thread.contacts ∩ the owner's combined-instance account contacts`**:

- **100% (13/13)** of *currently active/to-do* stale threads attribute (the set where Direction B matters now).
- **99.8% (4,355/4,362)** of the reporting user's Gmail threads attribute.
- **~74% (6,954 unique + 304 multi-account tie-broken)** of all stale threads attribute. The unattributable
  ~26% are dormant bulk/list/BCC mail whose contacts don't include the account address — users rarely star
  these. They are **left unchanged (status quo, no regression)**; Direction A still self-heals them on resync.

This is therefore a **best-effort** repair that fixes everything that matters today. (Email-based matching and
the creator-instance `actor_id` signal were tested and add nothing beyond the contacts join.)

## The operation

Run as one transaction against prod, connected as a **privileged role that owns `public.thread`** (the same
role used for the cutover SQL — `postgres`/`migrator`; `readonly` cannot `ALTER TABLE … DISABLE TRIGGER`).

> ⚠️ `ALTER TABLE public.thread DISABLE TRIGGER …` takes an `ACCESS EXCLUSIVE` lock on `thread` for the
> transaction. ~7k row updates are fast (sub-second), but it briefly blocks all `thread` reads/writes — run
> in a low-traffic window. The lock releases the instant the trigger is re-enabled (before the link update).

```sql
BEGIN;

-- 1. Resolve each stale thread to its account's active combined instance.
CREATE TEMP TABLE remap ON COMMIT DROP AS
WITH legacy_pkg(pkg) AS (VALUES
  ('7176b853-4495-4bba-82ee-645ae5d398d7'::uuid),   -- Gmail
  ('2ed4fcf8-6524-410f-b318-f9316e71c8b0'::uuid),   -- Google Calendar
  ('019d4129-4aee-7629-9d7b-b9fdb87db532'::uuid)),  -- Google Tasks
stale AS (
  SELECT a.id AS thread_id, ti.owner_id, a.contacts
  FROM public.thread a
  JOIN public.twist_instance ti ON ti.id = a.created_by AND ti.archived_at IS NOT NULL
  JOIN public.twist t ON t.id = ti.twist_id
  JOIN legacy_pkg lp ON lp.pkg = t.twist_package_id
  WHERE a.archived_at IS NULL
),
combined AS (   -- one row per (owner, account); healthy = connected, not needs_reauth
  SELECT cti.owner_id, cti.id AS instance_id, tic.actor_id,
         (tic.needs_reauth_at IS NULL) AS healthy
  FROM public.twist_instance cti
  JOIN public.twist ct ON ct.id = cti.twist_id
   AND ct.twist_package_id = '6e9e441f-aeee-4142-a37b-62cfe79ac16d'
  JOIN public.twist_instance_connection tic
   ON tic.twist_instance_id = cti.id AND tic.provider = 'google'
  WHERE cti.archived_at IS NULL
),
ranked AS (   -- attribute via contacts; tie-break multi-account threads toward a connected account
  SELECT s.thread_id, s.owner_id, c.instance_id,
         row_number() OVER (PARTITION BY s.thread_id
                            ORDER BY c.healthy DESC, c.actor_id) AS rnk
  FROM stale s
  JOIN combined c ON c.owner_id = s.owner_id AND c.actor_id = ANY (s.contacts)
)
SELECT thread_id, owner_id, instance_id AS target
FROM ranked WHERE rnk = 1;

-- BEFORE: review counts against the dry-run (expect ~7,258 total; ~6,954 unique + 304 tie-broken).
SELECT count(*) AS threads_to_remap FROM remap;

-- 2. Remap thread.created_by (bypass the immutability trigger; the seq/updated_at
--    trigger stays enabled, so each changed row bumps seq and re-syncs to clients).
ALTER TABLE public.thread DISABLE TRIGGER protect_thread_created_by_trigger;
UPDATE public.thread th
SET created_by = r.target
FROM remap r
WHERE th.id = r.thread_id
  AND th.created_by <> r.target;
ALTER TABLE public.thread ENABLE TRIGGER protect_thread_created_by_trigger;

-- 3. Remap link.created_by for those threads' links still owned by an archived
--    legacy Google instance (link has no protection trigger). Leave twist_id and
--    any user-/other-connector-owned links untouched.
UPDATE public.link l
SET created_by = r.target
FROM remap r
WHERE l.thread_id = r.thread_id
  AND l.created_by IN (
    SELECT ti.id FROM public.twist_instance ti
    JOIN public.twist t ON t.id = ti.twist_id
    WHERE ti.archived_at IS NOT NULL
      AND t.twist_package_id IN (
        '7176b853-4495-4bba-82ee-645ae5d398d7',
        '2ed4fcf8-6524-410f-b318-f9316e71c8b0',
        '019d4129-4aee-7629-9d7b-b9fdb87db532'));

-- AFTER (still inside the txn): both should report 0 remaining for attributed threads.
SELECT count(*) AS thread_created_by_still_stale
FROM public.thread th JOIN remap r ON r.thread_id = th.id
WHERE th.created_by <> r.target;

SELECT count(*) AS link_created_by_still_stale
FROM public.link l JOIN remap r ON r.thread_id = l.thread_id
WHERE l.created_by IN (
  SELECT ti.id FROM public.twist_instance ti JOIN public.twist t ON t.id = ti.twist_id
  WHERE ti.archived_at IS NOT NULL AND t.twist_package_id IN (
    '7176b853-4495-4bba-82ee-645ae5d398d7','2ed4fcf8-6524-410f-b318-f9316e71c8b0','019d4129-4aee-7629-9d7b-b9fdb87db532'));

-- If the AFTER counts are 0 and threads_to_remap matched the dry-run: COMMIT. Else ROLLBACK.
COMMIT;
```

### What is intentionally NOT changed
- **`thread.twist_id` / `link.twist_id`** — left as the legacy package id. Write-back dispatch keys on
  `created_by`, never `twist_id`; `thread.twist_id` is load-bearing for `(twist_id, key)` cross-instance
  dedup and documented immutable. Leaving it preserves dedup identity and is harmless to write-back. (It is a
  cosmetic creator/twist mismatch on these rows; it self-corrects on the next full convergence sync.)
- **Unattributable threads (~26%)** — left entirely as-is. No regression; Direction A still self-heals them.

## Verify post-op (after COMMIT)
- In the app: star a previously-synced Gmail email → it appears as a to-do/active in Plot (Direction A); mark
  a pre-cutover email active in Plot → it gets starred in Gmail (Direction B). (Direction B requires the
  account to be reconnected, i.e. its combined instance not `needs_reauth`.)
- `setThreadToDo: no link found` warnings for `https://mail.google.com/...` sources should stop in logs.

## Rollback
- **Before COMMIT:** `ROLLBACK` — nothing changed.
- **After COMMIT:** the prior `created_by` values were the archived legacy instances; if a revert is needed,
  re-point the affected threads/links back. Practically there is no reason to revert — the prior state was the
  broken state. (If required, capture the `remap` table to a permanent table before COMMIT so the old→new
  mapping is recorded for an exact reversal.)

## Local validation done (2026-06-29)
- Attribution + scope counts above are from prod read-only dry-runs of the exact CTE.
- The trigger-bypass mechanic was probed on the local dev DB inside a rolled-back txn: a plain
  `UPDATE thread SET created_by` is reverted by the trigger (but still bumps seq — the silent-no-op trap);
  `DISABLE TRIGGER` + UPDATE changes `created_by` and bumps seq.
