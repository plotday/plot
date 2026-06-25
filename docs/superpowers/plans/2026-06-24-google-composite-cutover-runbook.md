# Google Composite Connection — Catalog Cutover & Bankruptcy Runbook (Phase 4/6)

_Authored 2026-06-24. This is the **ops runbook** for the final phase of the combined Google connection.
Everything before this shipped: Flutter UX (#416/#426/#430), SDK + Phase-1 view (#218/#417), the combined
connector with all four products re-homed (plotday/plot **#222** — public/main `c5cffe8`), and the Phase-4
endpoint (plotday/core **#431**). What remains is **operational**, not code: deploy the connector, hide the
three legacy sources, archive users' legacy instances, and prompt re-add._

## Why this is a manual operation (NOT an auto-applied migration)

The bankruptcy archives real prod `twist` / `twist_instance` rows and **must be sequenced** against a connector
deploy and an app release. A DB migration is the wrong vehicle:

- Atlas migrations apply **once** on the **next deploy of every environment** — merging one would trigger the
  bankruptcy whenever the next unrelated deploy runs, possibly **before** the combined connector is deployed and
  the app prompt ships, stranding every Google user with no source and no prompt.
- A guard ("only archive if the combined twist exists") doesn't help: a migration is evaluated **once**, so if it
  no-ops on first apply it never re-runs.

So the archival is a **coordinated, manually-run prod SQL operation**, executed at the right moment in the
sequence below. The SQL is validated (parses + correct columns) against the worktree DB; in prod it matches the
real rows.

## Identifiers (stable across environments — these are connector `plotTwistId`s = `twist.twist_package_id`)

| Connector | `twist_package_id` | catalog `name` |
|---|---|---|
| **Combined (new)** | `6e9e441f-aeee-4142-a37b-62cfe79ac16d` | "Google Mail, Calendar, and Tasks" |
| Gmail (legacy) | `7176b853-4495-4bba-82ee-645ae5d398d7` | "Gmail" |
| Google Calendar (legacy) | `2ed4fcf8-6524-410f-b318-f9316e71c8b0` | "Google Calendar" |
| Google Tasks (legacy) | `019d4129-4aee-7629-9d7b-b9fdb87db532` | "Google Tasks" |

> ⚠️ **Pre-req: confirm the combined `plotTwistId` is FINAL** before the first prod deploy. It was carried from
> the Phase-2 scaffold and flagged as a possible placeholder. Once deployed it becomes the permanent catalog
> identity (`twist.twist_package_id`, unique per environment) and changing it later orphans connections. Verify
> it's a deliberate, unique UUID in `public/connectors/google/package.json`.

## How the pieces actually work (verified against the code)

- A catalog source is a `twist` row with `is_source = true` and `archived_at IS NULL`. Rows are created/updated
  by **`deployTwist()`** (`workers/api/src/twist/deployment.ts`) when the connector is deployed (`plot deploy`)
  — **not** by a seed/migration. So the combined catalog row only exists after the connector is deployed to the
  environment.
- Hiding a source = `UPDATE twist SET archived_at = now()`. Both `twist` and `twist_instance` carry a `seq`
  bumped automatically on every UPDATE (`update_seq_and_updated_at` trigger), so setting `archived_at`
  propagates to clients via the seq-cursor sync — old instances show as removed, the hidden source drops out of
  the picker. **Never `DELETE`** (synced-table rule).
- Convergence on re-add: the combined connector re-emits the **same globally-unique `source` keys** as the
  legacy connectors, so upsert-by-`source` converges new syncs onto the existing threads/links rather than
  duplicating them. Accept a small dup window for very recent items (known cost of bankruptcy).

---

## Cutover sequence (run in order)

### 0. Pre-reqs
- [ ] #431 merged to core/main (Phase-4 endpoint live). ✅ done
- [ ] public/main carries the combined connector (`c5cffe8`). ✅ done
- [ ] Combined connector `plotTwistId` confirmed final (see warning above). **Confirm the combined `plotTwistId` is final before running any step below — the provisioning + status queries in §3 and §4 key on it.**
- [ ] (Optional) add `filterText` search aliases to the combined source so it's findable by
      `gmail, mail, email, inbox, calendar, gcal, agenda, tasks, todo, contacts, google, workspace` (spec §4.5).
      Neither the legacy nor combined connectors declare `filterText` today, so this is additive polish, not a
      regression — confirm where the catalog reads search text from before relying on it.

### 1. Deploy the combined connector to prod
```bash
cd public/connectors/google
pnpm exec plot deploy        # prod target; creates/updates the combined twist row (is_source=true)
```
This is **safe to do early**: the catalog now lists the combined source *alongside* the three legacy ones (the
spec §4.5 "both visible until cutover" state). Nothing is archived yet.

**Verify the catalog row landed** (prod DB, read-only — use the `prod-db-investigate` skill, port 5433):
```sql
SELECT id, name, is_source, archived_at,
       (permissions ? '_products')           AS has_products,
       (permissions ->> '_dynamic_link_types') AS dyn_link_types
FROM public.twist
WHERE twist_package_id = '6e9e441f-aeee-4142-a37b-62cfe79ac16d';
-- expect: is_source=t, archived_at=NULL, has_products=t, dyn_link_types=true
```

### 2. Release the app build carrying the re-add prompt
Ship the iOS/Android/desktop/web build with the "Google connections upgraded — reconnect to keep syncing"
notice (see **Re-add prompt** below). Ship this **before** step 3 so that the moment instances are archived,
users on the new build are prompted and can re-add immediately. (Users on older builds simply see their Google
connection removed in Connections and can re-add organically.)

### 3. Run the bankruptcy provisioning SQL in prod
Run as one transaction against the prod DB (writable session). **Capture the BEFORE counts first.**
```sql
-- BEFORE: how many legacy instances + distinct Google accounts will be touched (read-only)
SELECT t.name,
       count(ti.*) AS active_instances,
       count(DISTINCT tic.actor_id) AS distinct_google_accounts
FROM public.twist t
LEFT JOIN public.twist_instance ti ON ti.twist_id = t.id AND ti.archived_at IS NULL
LEFT JOIN public.twist_instance_connection tic ON tic.twist_instance_id = ti.id
WHERE t.twist_package_id IN (
  '7176b853-4495-4bba-82ee-645ae5d398d7',
  '2ed4fcf8-6524-410f-b318-f9316e71c8b0',
  '019d4129-4aee-7629-9d7b-b9fdb87db532'
)
GROUP BY t.name;

BEGIN;

-- 3a. For each (user, distinct Google account, team) that has an active legacy
-- Gmail/Calendar/Tasks connection, provision one combined Google instance in a
-- needs-auth + seed-defaults state. The seed_default_channels=true flag causes
-- setChannels() to auto-enable the user's owned channels on first reconnect.
WITH legacy AS (
  SELECT DISTINCT ti.owner_id, ti.team_id, tic.actor_id
  FROM public.twist_instance ti
  JOIN public.twist t ON t.id = ti.twist_id
  JOIN public.twist_instance_connection tic
    ON tic.twist_instance_id = ti.id AND tic.provider = 'google'
  WHERE t.twist_package_id IN (
    '7176b853-4495-4bba-82ee-645ae5d398d7',  -- Gmail
    '2ed4fcf8-6524-410f-b318-f9316e71c8b0',  -- Google Calendar
    '019d4129-4aee-7629-9d7b-b9fdb87db532'   -- Google Tasks
  )
  AND ti.archived_at IS NULL
),
combined AS (
  SELECT id AS twist_id FROM public.twist
  WHERE twist_package_id = '6e9e441f-aeee-4142-a37b-62cfe79ac16d' AND is_source = true
  LIMIT 1
),
created AS (
  INSERT INTO public.twist_instance (id, twist_id, owner_id, team_id, name, draft)
  SELECT gen_random_uuid(), c.twist_id, l.owner_id, l.team_id,
         'Google Mail, Calendar, and Tasks', false
  FROM legacy l CROSS JOIN combined c
  -- guard: skip accounts that already have a combined instance
  WHERE NOT EXISTS (
    SELECT 1 FROM public.twist_instance ti2
    JOIN public.twist_instance_connection tic2
      ON tic2.twist_instance_id = ti2.id
    WHERE ti2.twist_id = c.twist_id AND ti2.owner_id = l.owner_id
      AND ti2.archived_at IS NULL AND tic2.actor_id = l.actor_id
  )
  RETURNING id, owner_id, team_id
)
INSERT INTO public.twist_instance_connection
  (twist_instance_id, user_id, provider, actor_id, needs_reauth_at, seed_default_channels)
SELECT cr.id, cr.owner_id, 'google', l.actor_id, now(), true
FROM created cr
JOIN legacy l ON l.owner_id = cr.owner_id AND l.team_id IS NOT DISTINCT FROM cr.team_id;

-- 3b. Archive every user-owned instance of the legacy connectors. Channels and
-- already-synced threads/links remain as historical content (never deleted).
UPDATE public.twist_instance SET archived_at = now()
WHERE twist_id IN (SELECT id FROM public.twist WHERE twist_package_id IN (
  '7176b853-4495-4bba-82ee-645ae5d398d7',
  '2ed4fcf8-6524-410f-b318-f9316e71c8b0',
  '019d4129-4aee-7629-9d7b-b9fdb87db532'))
AND archived_at IS NULL;

-- 3c. Hide the three legacy catalog sources (drops them from the add-connection picker).
UPDATE public.twist SET archived_at = now()
WHERE twist_package_id IN (
  '7176b853-4495-4bba-82ee-645ae5d398d7',
  '2ed4fcf8-6524-410f-b318-f9316e71c8b0',
  '019d4129-4aee-7629-9d7b-b9fdb87db532'
)
AND archived_at IS NULL;

-- Review INSERT/UPDATE counts against the BEFORE query, THEN:
COMMIT;   -- (ROLLBACK instead if the counts look wrong)
```
> Validated locally (worktree DB, rolled back 2026-06-24): all statements parse and run; matched 0 rows locally
> because the legacy/combined Google connectors aren't deployed to the dev DB — in prod they match the real rows.
> `archived_at` auto-bumps `seq` on both tables, so clients re-sync the archival. The provisioned
> `needs_reauth_at` connection triggers the re-add prompt; `seed_default_channels=true` auto-enables owned
> channels when the user reconnects.

### 4. Verify post-cutover
```sql
-- Catalog: only the combined Google source is active now.
SELECT name, archived_at FROM public.twist
WHERE twist_package_id IN (
  '6e9e441f-aeee-4142-a37b-62cfe79ac16d',
  '7176b853-4495-4bba-82ee-645ae5d398d7',
  '2ed4fcf8-6524-410f-b318-f9316e71c8b0',
  '019d4129-4aee-7629-9d7b-b9fdb87db532'
);
-- expect: combined archived_at=NULL; the 3 legacy archived_at set.

-- No active legacy instances remain.
SELECT count(*) FROM public.twist_instance ti
JOIN public.twist t ON t.id = ti.twist_id
WHERE t.twist_package_id IN (
  '7176b853-4495-4bba-82ee-645ae5d398d7',
  '2ed4fcf8-6524-410f-b318-f9316e71c8b0',
  '019d4129-4aee-7629-9d7b-b9fdb87db532'
) AND ti.archived_at IS NULL;   -- expect 0

-- One combined needs-auth connection exists per legacy Google account.
-- Row count should equal the number of distinct Google accounts from the BEFORE query.
SELECT count(*) AS combined_instances,
       count(DISTINCT tic.actor_id) AS distinct_google_accounts
FROM public.twist_instance ti
JOIN public.twist t ON t.id = ti.twist_id
JOIN public.twist_instance_connection tic ON tic.twist_instance_id = ti.id
WHERE t.twist_package_id = '6e9e441f-aeee-4142-a37b-62cfe79ac16d'
  AND ti.archived_at IS NULL
  AND tic.needs_reauth_at IS NOT NULL
  AND tic.seed_default_channels = true;
-- expect: combined_instances = distinct_google_accounts = (BEFORE distinct_google_accounts)
```
- [ ] App: add-connection picker shows ONE "Google Mail, Calendar, and Tasks" (no Gmail/Calendar/Tasks).
- [ ] App: previously-connected users see the re-add prompt; old instances show as removed.
- [ ] App: after reconnecting a Google account, the user's previously-owned channels (Gmail, Calendar, Tasks)
      enable automatically and sync resumes — confirming `seed_default_channels` + `setChannels()` worked.
      (Live verification with a real Google account required.)

### 5. Verify convergence (the spec's flagged risk — eyes-on)
Pick a test account that had a legacy Google connection, re-add the combined connector, grant scopes, and
confirm:
- [ ] Calendar events / emails / tasks re-sync onto the **existing** threads (no duplicate threads for items
      that were already synced) — upsert-by-`source` convergence.
- [ ] Accept any small duplication only for very-recent items (known bankruptcy cost).

---

## Re-add prompt (the one app-side code change — not yet built)

Reuse the connection-status-tile / one-time-notice pattern. Data-driven detection on session load:

- Query the synced store for **archived `twist_instance` rows whose `twist` is one of the three legacy Google
  `twist_package_id`s** (or, simpler client-side: the user has no active Google source but has archived Google
  instances). If found, show a dismissible banner on the Connections screen:
  > "We've combined your Google connections — reconnect to keep syncing." → **[Reconnect]** opens the combined
  > "Google Mail, Calendar, and Tasks" entry in the add-connection picker.
- One re-auth grants the union of granted scopes; the composite status screen then reflects the products.
- Dismiss once per user (persist a flag) so it doesn't nag after they reconnect or dismiss.

This is buildable + widget-testable in Flutter independently; it should ship **with or before** step 3.

---

## Rollback

- **Before COMMIT in step 3:** `ROLLBACK` — nothing changed.
- **After COMMIT:** un-archive by clearing `archived_at` on the affected rows (the `seq` bump re-syncs the
  un-archival):
  ```sql
  UPDATE public.twist SET archived_at = NULL
  WHERE twist_package_id IN ('7176b853-…','2ed4fcf8-…','019d4129-…');
  -- and the instances archived in this window (scope by the archival timestamp you captured):
  UPDATE public.twist_instance SET archived_at = NULL
  WHERE twist_id IN (SELECT id FROM public.twist WHERE twist_package_id IN ('7176b853-…','2ed4fcf8-…','019d4129-…'))
    AND archived_at >= '<the COMMIT timestamp>';
  ```
  (Scope the instance un-archive by timestamp so you don't revive connections the user had archived themselves
  earlier.) The combined connector can stay deployed regardless — it's additive.

## What's locally-doable vs prod-gated (summary)

| Step | Locally | Prod-gated |
|---|---|---|
| Provisioning SQL authored + syntax-validated | ✅ (this doc; rolled back on worktree DB 2026-06-24) | — |
| Deploy combined connector (creates catalog row) | — | ✅ `plot deploy` to prod |
| Provision combined instances + archive legacy + hide sources | — | ✅ run §3 SQL in prod |
| Re-add prompt | ✅ build + widget-test | ✅ ships in app release |
| Reconnect auto-enables owned channels (`seed_default_channels`) | ✅ schema + `setChannels()` seeding done | ✅ verify with real Google account |
| Convergence verification | — | ✅ needs a real re-add + Google sync |
