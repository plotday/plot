# Phase 2 — DB team scoping (expand) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax. Follow the schema-change workflow in `libs/db/AGENTS.md` exactly: edit schema files → `pnpm gen-migration` → append data migration → `pnpm apply-migrations` → `pnpm diff-schema-migrations` → commit regenerated `libs/db/src/types.ts`.

**Goal:** Move the team-visibility firewall from the *filed priority's* `team_id` onto the *thread's own* `team_id`, with an `external_contacts` exemption for non-team (customer) participants, so every thread carries an enforceable team scope. This is the **expand** half of expand/contract — it adds columns and rekeys the gate without dropping `priority.team_id` (that's Phase 6).

**Architecture:** A refactor of the existing priority-keyed firewall in `user.thread` (`90-user-schema/30-thread.sql:215`) to a thread-keyed one, plus: two new `thread` columns, one BEFORE-trigger (connector team default + immutability + point-in-time external classification), repointed team-leave revocation, a re-join un-revoke trigger, `upsert_thread` carrying `team_id`, and the worker thread-sync passthrough. No notify/Zod mirror exists (sync is seq-based via `user.thread`).

**Tech Stack:** PostgreSQL 18, Atlas migrations, Cloudflare Workers (TS) for the sync handler.

**Pre-req:** On `feat/two-step-thread-creation`. If in a worktree, ensure the isolated DB is up: `bash scripts/worktree-db`. **Always use `$DATABASE_URL`** for psql — never hardcode 54322. Phase 1 need not be merged first (independent).

**Invariants to preserve (from the source files):**
- `thread.external_contacts ⊆ thread.contacts` always (the trigger guarantees it).
- `thread.team_id` is set at creation and locked thereafter, except a one-time `NULL → value` transition (backfill / personal→team promotion).
- Classification is **point-in-time**: a teammate added while a member stays gated (loses access on leave); a contact added while not a member is exempt forever.
- Never bare-`DELETE` synced rows; access loss uses `thread_priority.revoked_at` + the existing `user.thread_redacted` stub (`libs/db/AGENTS.md`).

---

### Task 1: Add `team_id` and `external_contacts` columns to `thread`

**Files:**
- Modify: `libs/db/schema/50-tables/24-thread.sql`

- [ ] **Step 1: Add the columns + index + comments**

In `libs/db/schema/50-tables/24-thread.sql`, immediately after the `merged_into_thread_id` column (before the closing `);` at line ~64-65), add:

```sql
    ,
    -- Team scope. NULL = personal (ungated). Set at creation and locked
    -- thereafter (one-time NULL→value allowed for backfill / promotion).
    -- For connector threads, defaulted from the creating
    -- twist_instance.team_id by set_thread_team_and_external. The team
    -- firewall in user.thread gates visibility on this column.
    "team_id" bigint REFERENCES public.team (id) ON DELETE RESTRICT,
    -- Subset of `contacts` that are NOT subject to the team-membership gate
    -- (non-team "customer" participants). Captured point-in-time when a
    -- contact is added to a team thread: a contact whose linked user is not
    -- a current member of team_id at add-time is recorded here and stays
    -- exempt. Maintained exclusively by set_thread_team_and_external; never
    -- written directly. Always a subset of contacts.
    "external_contacts" uuid[] NOT NULL DEFAULT ARRAY[]::uuid[]
```

Then add indexes near the other `thread` indexes (after `idx_thread_groups`, ~line 117):

```sql
CREATE INDEX idx_thread_team_id ON "public"."thread" ("team_id") WHERE team_id IS NOT NULL;

CREATE INDEX idx_thread_external_contacts ON "public"."thread" USING gin ("external_contacts");
```

- [ ] **Step 2: Sanity-check the file parses (no migration yet)**

Run:
```bash
cd /Users/kris.braun/code/plot && rg -n "team_id|external_contacts" libs/db/schema/50-tables/24-thread.sql
```
Expected: shows the two new columns and two new indexes.

---

### Task 2: BEFORE trigger — connector team default, immutability, point-in-time external classification

**Files:**
- Create: `libs/db/schema/95-triggers/29-thread_team.sql`

- [ ] **Step 1: Write the trigger function + trigger**

Create `libs/db/schema/95-triggers/29-thread_team.sql`:

```sql
-- Maintains thread.team_id and thread.external_contacts.
--
-- team_id:
--   • INSERT: if NULL and created_by is a twist_instance, inherit that
--     connection's team (connector threads are team threads). User threads
--     pass team_id explicitly via upsert_thread.
--   • UPDATE: locked once set (NULL→value allowed once, for backfill or a
--     personal→team promotion).
--
-- external_contacts (only for team-scoped threads): the subset of contacts
-- exempt from the team-membership gate. POINT-IN-TIME — a contact added
-- while NOT a current member of team_id is recorded as external and stays
-- exempt; a contact added while a member is left gated (so it loses access
-- if it later leaves the team). Prior external decisions are preserved for
-- contacts still present; classification re-runs only for newly-added
-- contacts (or all contacts when the thread first becomes team-scoped).
CREATE OR REPLACE FUNCTION public.set_thread_team_and_external ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_old_contacts uuid[] := ARRAY[]::uuid[];
    v_old_external uuid[] := ARRAY[]::uuid[];
    v_classify_all boolean := FALSE;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.team_id IS NULL THEN
            -- Connector-created threads inherit the connection's team.
            SELECT ti.team_id INTO NEW.team_id
            FROM twist_instance ti
            WHERE ti.id = NEW.created_by;
        END IF;
        v_classify_all := (NEW.team_id IS NOT NULL);
    ELSE  -- UPDATE
        v_old_contacts := COALESCE(OLD.contacts, ARRAY[]::uuid[]);
        v_old_external := COALESCE(OLD.external_contacts, ARRAY[]::uuid[]);
        IF OLD.team_id IS NOT NULL AND NEW.team_id IS DISTINCT FROM OLD.team_id THEN
            NEW.team_id := OLD.team_id;  -- locked once set
        END IF;
        -- NULL→value transition (backfill / promotion) reclassifies all
        -- current contacts at this instant.
        v_classify_all := (OLD.team_id IS NULL AND NEW.team_id IS NOT NULL);
    END IF;

    IF NEW.team_id IS NULL THEN
        NEW.external_contacts := ARRAY[]::uuid[];
        RETURN NEW;
    END IF;

    NEW.external_contacts := (
        SELECT COALESCE(array_agg(DISTINCT c), ARRAY[]::uuid[])::uuid[]
        FROM (
            -- Prior external decisions, limited to still-present contacts.
            SELECT c FROM unnest(v_old_external) AS c
            WHERE c = ANY(COALESCE(NEW.contacts, ARRAY[]::uuid[]))
            UNION
            -- Newly-added (or all, when first team-scoped) contacts with no
            -- current member of NEW.team_id linked to them → exempt.
            SELECT c FROM unnest(COALESCE(NEW.contacts, ARRAY[]::uuid[])) AS c
            WHERE (v_classify_all OR c <> ALL(v_old_contacts))
              AND NOT EXISTS (
                  SELECT 1
                  FROM user_contact uc
                  JOIN team_user tu
                    ON tu.user_id = uc.user_id
                   AND tu.team_id = NEW.team_id
                   AND tu.archived_at IS NULL
                  WHERE uc.contact_id = c
                    AND uc.linked = TRUE
                    AND uc.archived_at IS NULL
              )
        ) s
    );

    RETURN NEW;
END;
$$;

-- Fire on the columns that affect the computation. Including external_contacts
-- in the OF list means any direct write to it is re-sanitized (recomputed),
-- so the column stays server-controlled.
CREATE TRIGGER set_thread_team_and_external
    BEFORE INSERT OR UPDATE OF contacts, team_id, external_contacts, created_by
    ON public.thread
    FOR EACH ROW
    EXECUTE FUNCTION public.set_thread_team_and_external ();
```

(`95-triggers/` loads after tables and functions, so `twist_instance`, `team_user`, `user_contact` all exist.)

---

### Task 3: Rekey the `user.thread` team firewall onto the thread; expose `team_id`

**Files:**
- Modify: `libs/db/schema/90-user-schema/30-thread.sql`

- [ ] **Step 1: Expose `team_id` in `user.thread`**

In the `user.thread` SELECT, add `a.team_id` right after the `a.groups,` line (~line 58):

```sql
    a.groups,
    a.team_id,
    a.topic,
```

- [ ] **Step 2: Add the matching column to `user.thread_redacted`**

In `user.thread_redacted`, add a NULL placeholder at the matching position (after the `groups` line, ~line 271):

```sql
    CAST(ARRAY[]::uuid[] AS uuid[]) AS groups,
    NULL::bigint AS team_id,
    NULL::text AS topic,
```

(Both views must expose the same columns — the sync handler merges them.)

- [ ] **Step 3: Drop the now-unneeded `JOIN priority p`**

In `user.thread`, delete the comment block + join (currently ~lines 190-195):

```sql
    -- Effective priority join: case-A pending rows (priority_id NULL)
    -- fall back to the user's root priority for the team-firewall check
    -- below. Root priorities are user-owned, so team_id IS NULL and the
    -- check trivially passes — which matches the COALESCE-to-root
    -- behavior of the priority_id column the view exposes.
    JOIN priority p ON p.id = "user".effective_priority_id(tp.priority_id, tp.user_id)
```

(`p` is referenced only by the firewall; `effective_priority_id(...)` is still used in the SELECT and the `upe` join, which stay.)

- [ ] **Step 4: Rekey the firewall onto `a.team_id` + exemption**

Replace the existing firewall block (currently ~lines 215-225):

```sql
    -- Team firewall: a thread filed under a team-scoped priority is only
    -- visible to current members of that team.
    AND (
        p.team_id IS NULL
        OR EXISTS (
            SELECT 1 FROM public.team_user tu2
            WHERE tu2.team_id = p.team_id
              AND tu2.user_id = tp.user_id
              AND tu2.archived_at IS NULL
        )
    );
```

with:

```sql
    -- Team firewall (thread-scoped): a team thread is visible only to current
    -- members of thread.team_id, EXCEPT contacts explicitly marked external
    -- (non-team customers), who are exempt. Personal threads (team_id NULL)
    -- are ungated. Keyed on the thread's own team_id (was: the filed
    -- priority's team_id) so it survives the removal of priority.team_id.
    AND (
        a.team_id IS NULL
        OR a.external_contacts && "user".user_contact_ids(tp.user_id)
        OR EXISTS (
            SELECT 1 FROM public.team_user tu2
            WHERE tu2.team_id = a.team_id
              AND tu2.user_id = tp.user_id
              AND tu2.archived_at IS NULL
        )
    );
```

---

### Task 4: Write `thread.team_id` in `user.upsert_thread`

**Files:**
- Modify: `libs/db/schema/90-user-schema/80-upsert_thread.sql`

- [ ] **Step 1: Add `team_id` to the INSERT column list**

In the `INSERT INTO thread (...)` (currently ~line 359-362), append `team_id` to the column list:

```sql
    INSERT INTO thread (
        id, created_by, title, preview, updated_by, sync_depth, contacts, contact_meta, groups, topic,
        draft, key, icon, twist_id, pending_contacts, team_id
    )
```

- [ ] **Step 2: Add the value (last in the VALUES list, after the `pending_contacts` ARRAY)**

The `VALUES (...)` block ends with the `pending_contacts` value:
```sql
        -- pending_contacts on the INSERT path starts empty; entries are added
        -- below only when the caller cannot attest themselves.
        ARRAY[]::uuid[]
    )
```
Change it to add `team_id` after it:
```sql
        -- pending_contacts on the INSERT path starts empty; entries are added
        -- below only when the caller cannot attest themselves.
        ARRAY[]::uuid[],
        -- team_id: explicit from the caller (user-composed Note/Chat) or
        -- NULL for connector threads, which set_thread_team_and_external
        -- then defaults from the creating twist_instance.team_id.
        COALESCE((p_thread ->> 'team_id')::bigint, (p_defaults ->> 'team_id')::bigint)
    )
```

- [ ] **Step 3: Do NOT set `team_id` on the `ON CONFLICT … DO UPDATE` branch**

Leave the UPDATE branch unchanged — `team_id` is immutable after creation (the trigger enforces the lock even if a future caller tries). `external_contacts` is never in this function; the trigger computes it. Confirm you did not add `team_id` to the `DO UPDATE SET` list.

---

### Task 5: Repoint team-leave revocation onto `thread.team_id`; add re-join un-revoke

**Files:**
- Modify: `libs/db/schema/95-triggers/27-team_user_lifecycle.sql`

- [ ] **Step 1: Repoint the revocation UPDATE in `team_user_archive_priorities`**

Replace the first `UPDATE` in `team_user_archive_priorities` (currently keyed on `priority.team_id`):

```sql
    UPDATE public.thread_priority tp
    SET revoked_at = now()
    FROM public.priority p
    WHERE tp.priority_id = p.id
      AND tp.user_id = NEW.user_id
      AND p.team_id = NEW.team_id
      AND tp.revoked_at IS NULL;
```

with a thread-scoped revocation that exempts external contacts:

```sql
    -- Revoke the leaving user's access to this team's threads (keyed on the
    -- thread's own team_id). External (customer) contacts are exempt — they
    -- keep access even after the user leaves the team.
    UPDATE public.thread_priority tp
    SET revoked_at = now()
    FROM public.thread t
    WHERE tp.thread_id = t.id
      AND tp.user_id = NEW.user_id
      AND t.team_id = NEW.team_id
      AND NOT (t.external_contacts && "user".user_contact_ids(NEW.user_id))
      AND tp.revoked_at IS NULL;
```

Leave the second `UPDATE public.priority SET archived_at …` block unchanged (it still archives the user's team focuses during the expand window; Phase 6 removes it together with `priority.team_id`).

- [ ] **Step 2: Add a re-join un-revoke trigger at the end of the file**

Append:

```sql
-- On (re)joining a team — INSERT of an active membership or un-archiving an
-- existing one — restore the user's access to that team's threads that were
-- previously revoked. Prior thread_priority filing is preserved (we only flip
-- revoked_at back to NULL). Mirrors the un-revoke branch in
-- file_thread_priority_on_group_member_change.
CREATE OR REPLACE FUNCTION public.team_user_unrevoke_team_threads ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE public.thread_priority tp
    SET revoked_at = NULL
    FROM public.thread t
    WHERE tp.thread_id = t.id
      AND tp.user_id = NEW.user_id
      AND t.team_id = NEW.team_id
      AND tp.revoked_at IS NOT NULL;
    RETURN NULL;
END;
$$;

CREATE TRIGGER team_user_unrevoke_team_threads
    AFTER INSERT OR UPDATE ON "public"."team_user"
    FOR EACH ROW
    WHEN (NEW.archived_at IS NULL)
    EXECUTE FUNCTION public.team_user_unrevoke_team_threads ();
```

---

### Task 6: Carry `team_id` through the worker thread-sync upsert

**Files:**
- Modify: `workers/api/src/app/sync/threads.ts` (the handler that calls `user.upsert_thread`)

- [ ] **Step 1: Find where `p_thread` is built**

```bash
cd /Users/kris.braun/code/plot && rg -n "upsert_thread|p_thread|team_id|teamId" workers/api/src/app/sync/threads.ts
```
Expected: locates the `rpc(... 'upsert_thread', { p_thread: {...} })`-style call and the object literal mapping client thread fields into `p_thread`.

- [ ] **Step 2: Add `team_id` to the mapping**

In the object passed as `p_thread`, add `team_id` from the incoming client thread row (the client sends `teamId`/`team_id`; match the casing the handler already uses for other fields, e.g. `contacts`, `groups`). Example shape (adapt to the file's existing variable names):

```ts
const pThread = {
  // …existing fields (id, title, preview, contacts, groups, topic, draft, icon, key, …)
  team_id: body.teamId ?? null,
};
```

Do not set it on any update-only path that should preserve immutability — `team_id` is only honored on insert (the trigger locks it). Passing it on every upsert is safe because the DB ignores changes once set.

- [ ] **Step 3: Lint the worker**

```bash
cd /Users/kris.braun/code/plot && pnpm --filter @plotday/api lint
```
Expected: passes.

---

### Task 7: Generate, backfill, apply the migration; regenerate types

**Files:**
- Create (generated): `libs/db/migrations/<timestamp>_thread_team_scoping.sql`
- Modify (regenerated): `libs/db/src/types.ts`

- [ ] **Step 1: Generate the migration from the schema files**

```bash
cd /Users/kris.braun/code/plot && pnpm gen-migration -- thread_team_scoping
```
Expected: a new timestamped file in `libs/db/migrations/` containing the `ALTER TABLE thread ADD COLUMN team_id/external_contacts`, the new indexes, the `set_thread_team_and_external` function+trigger, the `team_user_unrevoke_team_threads` function+trigger, the repointed `team_user_archive_priorities`, and the `CREATE OR REPLACE VIEW user.thread`/`thread_redacted`.

- [ ] **Step 2: Append the data backfill to the generated migration**

Open the generated file and append at the end:

```sql
-- ── Data migration: backfill thread.team_id ──────────────────────────────
-- The team_id-setting UPDATEs fire set_thread_team_and_external (NULL→value),
-- which populates external_contacts point-in-time from current membership.

-- Connector threads: inherit the creating twist_instance's team.
UPDATE public.thread t
SET team_id = ti.team_id
FROM public.twist_instance ti
WHERE t.created_by = ti.id
  AND ti.team_id IS NOT NULL
  AND t.team_id IS NULL;

-- User-created threads: team of the creator's filed priority.
UPDATE public.thread t
SET team_id = p.team_id
FROM public.thread_priority tp
JOIN public.priority p ON p.id = tp.priority_id
WHERE tp.thread_id = t.id
  AND tp.user_id = t.created_by
  AND p.team_id IS NOT NULL
  AND t.team_id IS NULL;
```

Because you hand-edited a generated migration, re-hash:
```bash
cd /Users/kris.braun/code/plot && atlas migrate hash --dir file://libs/db/migrations
```

- [ ] **Step 3: Apply and regenerate types**

```bash
cd /Users/kris.braun/code/plot && pnpm apply-migrations
```
Expected: applies cleanly; auto-runs `pnpm types`, updating `libs/db/src/types.ts` with `team_id: number | null` and `external_contacts: string[]` on `thread`.

- [ ] **Step 4: Verify schema/migration sync**

```bash
cd /Users/kris.braun/code/plot && pnpm diff-schema-migrations
```
Expected: no differences.

---

### Task 8: Verify the team firewall (structural + functional)

**Files:** none (verification); optionally add scenarios to `workers/api/__tests__`.

- [ ] **Step 1: Structural checks**

```bash
psql "$DATABASE_URL" -c "\d+ public.thread" | rg "team_id|external_contacts"
psql "$DATABASE_URL" -c "SELECT pg_get_functiondef('public.set_thread_team_and_external'::regproc)" | rg "external_contacts"
psql "$DATABASE_URL" -c "SELECT pg_get_viewdef('\"user\".thread', true)" | rg "team_id|external_contacts"
```
Expected: columns present; the view's WHERE references `a.team_id` and `a.external_contacts` (NOT `p.team_id`).

- [ ] **Step 2: Functional gate test (transaction-scoped fixture; rolls back)**

Run this self-contained script. It builds a team with a member (`alice`) and a non-member (`bob`), an external customer contact (`carol`, not on the team), a team thread shared with alice + carol, then asserts visibility before and after alice leaves. Adjust column names only if a referenced table differs.

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
-- Minimal fixtures (ids fixed for assertions).
INSERT INTO "user"(id) VALUES
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');  -- alice(member), bob(non-member)
INSERT INTO contact(id) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001'),  -- alice contact
  ('bbbbbbbb-0000-0000-0000-000000000002'),  -- bob contact
  ('cccccccc-0000-0000-0000-000000000003');  -- carol (external customer, no user)
INSERT INTO user_contact(user_id, contact_id, linked) VALUES
  ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000001', true),
  ('22222222-2222-2222-2222-222222222222','bbbbbbbb-0000-0000-0000-000000000002', true);
-- Each user needs a root priority (firewall + filing rely on it).
INSERT INTO priority(id, created_by, user_id, title, path) VALUES
  ('dddddddd-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','root','r1'),
  ('dddddddd-0000-0000-0000-000000000002','22222222-2222-2222-2222-222222222222','22222222-2222-2222-2222-222222222222','root','r2');
INSERT INTO team(id, name) VALUES (999000, 'Acme') ON CONFLICT DO NOTHING;
INSERT INTO team_user(team_id, user_id, role) VALUES
  (999000,'11111111-1111-1111-1111-111111111111','member');  -- alice joins; bob does NOT

-- Team thread shared with alice (teammate) + carol (external). Author = alice.
INSERT INTO thread(id, created_by, title, contacts, team_id) VALUES
  ('eeeeeeee-0000-0000-0000-000000000001',
   '11111111-1111-1111-1111-111111111111', 'Team thread',
   ARRAY['aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-000000000003']::uuid[],
   999000);

-- Assert classification: carol external (no team member linked), alice not.
SELECT 'classify' AS check,
       external_contacts = ARRAY['cccccccc-0000-0000-0000-000000000003']::uuid[] AS ok
FROM thread WHERE id='eeeeeeee-0000-0000-0000-000000000001';

-- File alice (author) under her root so user.thread can surface it.
INSERT INTO thread_priority(thread_id, user_id, priority_id) VALUES
  ('eeeeeeee-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','dddddddd-0000-0000-0000-000000000001')
ON CONFLICT DO NOTHING;

-- Before leave: alice (member + recipient) sees it.
SELECT 'alice_sees_before' AS check,
       EXISTS(SELECT 1 FROM "user".thread WHERE user_id='11111111-1111-1111-1111-111111111111'
              AND id='eeeeeeee-0000-0000-0000-000000000001') AS ok;

-- Alice leaves the team.
UPDATE team_user SET archived_at = now()
WHERE team_id=999000 AND user_id='11111111-1111-1111-1111-111111111111';

-- After leave: alice no longer sees it in user.thread (gate fails),
-- and a redacted stub is emitted for cleanup.
SELECT 'alice_gone_after' AS check,
       NOT EXISTS(SELECT 1 FROM "user".thread WHERE user_id='11111111-1111-1111-1111-111111111111'
              AND id='eeeeeeee-0000-0000-0000-000000000001') AS ok;
SELECT 'alice_redacted_after' AS check,
       EXISTS(SELECT 1 FROM "user".thread_redacted WHERE user_id='11111111-1111-1111-1111-111111111111'
              AND id='eeeeeeee-0000-0000-0000-000000000001') AS ok;
ROLLBACK;
SQL
```
Expected: every `ok` column is `t` (true). If `user`/`contact`/`team` have additional NOT NULL columns without defaults in this schema, add them to the INSERTs (check with `\d public.<table>`); the assertions themselves should not change.

- [ ] **Step 3 (optional but recommended): add the scenario matrix to the integration suite**

If `workers/api/__tests__` has a DB harness, add cases mirroring Step 2 plus: member-recipient sees; non-member recipient (bob, if added as contact) does NOT see; external customer sees regardless of membership; re-join restores access (un-revoke); personal thread (team_id NULL) unaffected; point-in-time (teammate added then removed loses access; customer added stays). Run with `timeout` per the workers test-config note.

---

### Task 9: Commit

- [ ] **Step 1: Stage and commit the schema, migration, types, and worker change**

```bash
cd /Users/kris.braun/code/plot
git add libs/db/schema/50-tables/24-thread.sql \
        libs/db/schema/95-triggers/29-thread_team.sql \
        libs/db/schema/90-user-schema/30-thread.sql \
        libs/db/schema/90-user-schema/80-upsert_thread.sql \
        libs/db/schema/95-triggers/27-team_user_lifecycle.sql \
        libs/db/migrations/ libs/db/src/types.ts \
        workers/api/src/app/sync/threads.ts
git commit -m "feat(db): thread-scoped team firewall with external-contact exemption" \
  -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>" -- \
        libs/db/schema/50-tables/24-thread.sql \
        libs/db/schema/95-triggers/29-thread_team.sql \
        libs/db/schema/90-user-schema/30-thread.sql \
        libs/db/schema/90-user-schema/80-upsert_thread.sql \
        libs/db/schema/95-triggers/27-team_user_lifecycle.sql \
        libs/db/migrations libs/db/src/types.ts \
        workers/api/src/app/sync/threads.ts
```

---

## Phase 2 self-check (run against the spec)

- `thread.team_id` + `external_contacts` exist; `external_contacts ⊆ contacts`; both maintained only by the trigger.
- `user.thread` firewall keyed on `a.team_id` with the `external_contacts` exemption; `JOIN priority p` gone; `team_id` exposed; `user.thread_redacted` column shape matches.
- Connector threads inherit `twist_instance.team_id`; user threads carry client `team_id` through `threads.ts` → `upsert_thread`.
- Team-leave revokes by `thread.team_id` (customers exempt); re-join un-revokes.
- Backfill set `team_id` for existing connector + user threads and populated `external_contacts` point-in-time.
- `priority.team_id` / `default_*` still present (dropped in Phase 6); `team_user_ensure_team_priority` still creates team focuses (removed in Phase 6). No notify/Zod work (sync is seq-based).

## Hand-off to Phase 3

Clients can now receive `team_id` on threads and must start **sending** it (user-composed Note/Chat) and stop relying on `priority.team_id` / focus default-contacts. That's Phase 3 (Flutter store/types).
