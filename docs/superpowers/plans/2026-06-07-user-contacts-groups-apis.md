# User Contacts & Groups APIs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add offline-capable, cross-device-syncing user APIs to (a) add a contact by name+email, (b) rename a contact (per-user override), and (c) create / rename / change membership of groups — all routed through the existing `pending`-queue to `POST /sync/actors` and `POST /sync/groups`.

**Architecture:** Make the existing read-only `Actors` and `Groups` sync tables writable. New `user.save_user_contact` / `user.save_group` SQL functions do the work; thin `POST /sync/{actors,groups}` handlers call them via `rpcUser` + `notifyUserSync`. The Flutter client writes an optimistic row with `pending=2` and the generic `Store.push` outbox POSTs it. Contact ids are server-owned (email-keyed); the client uses its own id when the email is new and reconciles same-email/different-id duplicates on the next actor pull.

**Tech Stack:** PostgreSQL + Atlas migrations + pgTAP; Cloudflare Workers (Hono) + Kysely + vitest; Flutter + Drift.

---

## Reference facts (read before starting)

- **DB function param convention:** existing `user.*` mutation functions name the caller param `user_id` (bare, qualified as `<fn>.user_id` inside the body), NOT `p_user_id`. Match this.
- **`rpcUser` only typechecks for functions present in the generated `user` schema `Functions` map.** After creating each function you MUST run `pnpm apply-migrations` (which runs `pnpm types`) and commit `libs/db/src/types.ts`, or `rpcUser(trx, "save_user_contact", …)` won't compile.
- **Mutating RPCs must run inside `withUserDb`** (Hyperdrive treats `SELECT * FROM fn()` as a cacheable read otherwise). `withUserDb(c.var.db, userId, async (trx) => …)` provides the transaction. Do NOT open a nested transaction inside it.
- **seq bumps are automatic:** `user_contact`/`contact` writes bump their own `seq` (`update_seq_and_updated_at` BEFORE trigger); `group_member`/`group_admin` writes bump the parent `group.seq` via the statement-level triggers in `schema/95-triggers/24-group_auto_maintain.sql`. Your functions never bump seq manually.
- **Never bare-DELETE a synced row** generally — but `group_member` DELETE is the established pattern (it isn't its own sync entity; the parent `group.seq` bump re-emits the group with updated `member_contact_ids`). `public.remove_group_members` already does this; reuse it.
- **DB worktree caveat:** if you `bash scripts/worktree-db` mid-session, `$DATABASE_URL` may be stale — verify with `psql "$DATABASE_URL" -tAc "show port;"` before any migration; override from `.worktree-db` if needed.

## File Structure

**Database (`libs/db/`)**
- Create `schema/90-user-schema/83-save-user-contact.sql` — `user.save_user_contact`.
- Create `schema/90-user-schema/84-save-group.sql` — `user.save_group`.
- Generated: `migrations/<ts>_*.sql` (via `pnpm gen-migration`), `src/types.ts` (via `pnpm types`).
- Create `tests/45-save-user-contact.sql` — pgTAP for the contact function.
- Create `tests/46-save-group.sql` — pgTAP for the group function.

**API (`workers/api/`)**
- Modify `src/app/sync/actors.ts` — add `POST /sync/actors`.
- Modify `src/app/sync/groups.ts` — add `POST /sync/groups`.
- Create `src/app/sync/save-contact-group.test.ts` — real-DB `rpcUser` round-trip tests.

**Flutter (`apps/plot/`)**
- Modify `lib/store/actor.dart` — `ActorsBase.toBase`, `processPulledRows`, `Actor.push`.
- Modify `lib/store/group.dart` — `GroupsBase.toBase`, `Group.push`.
- Modify `lib/store/sync_orchestrator.dart` — flip `actor`/`group` `pushFn`.
- Create `lib/command/contact.dart` — `AddContact`, `RenameContact`.
- Modify `lib/command/group.dart` — add `CreateGroup`, `RenameGroup`; migrate `AddGroupMembers`/`RemoveGroupMembers` to offline writes.
- Create `test/store/actor_dedupe_test.dart` — email-keyed `processPulledRows` test.

---

# Part A — Database

### Task 1: `user.save_user_contact` function

**Files:**
- Create: `libs/db/schema/90-user-schema/83-save-user-contact.sql`

- [ ] **Step 1: Write the function**

Create `libs/db/schema/90-user-schema/83-save-user-contact.sql`:

```sql
-- Add or rename a contact in the calling user's address book. Offline-queued
-- via POST /sync/actors.
--
-- Modes:
--   * p_email NOT NULL -> ADD: resolve-or-create the global contact by email.
--     The client-provided p_contact_id is used as the new contact's id when the
--     email is brand new (so the optimistic client row keeps its id and needs no
--     reconciliation); on an existing email the existing contact id wins. The
--     global contact.name is NEVER written here -- user-entered names are a
--     per-user override only, so one user can't rename a contact for everyone.
--   * p_email NULL     -> RENAME: target the existing p_contact_id.
--
-- In both modes the per-user display name is written to user_contact.name with
-- source = 'user' -- the explicit, sticky override that bypasses the connector
-- longest-wins path (see public.upsert_user_contact_name). Inserting the
-- user_contact row is also what makes a brand-new external contact appear in
-- user.actor for this user.
--
-- Returns the resulting user.actor row for this user so the API can hand the
-- canonical contact id back to the client.
CREATE OR REPLACE FUNCTION "user".save_user_contact (
    user_id uuid,
    p_contact_id uuid,
    p_email text,
    p_name text
)
    RETURNS SETOF "user"."actor"
    LANGUAGE plpgsql
    AS $function$
DECLARE
    v_contact_id uuid;
BEGIN
    IF p_contact_id IS NULL THEN
        RAISE EXCEPTION 'Contact id is required';
    END IF;

    IF p_email IS NOT NULL THEN
        -- Minimal email shape check, mirroring public.upsert_contacts.
        IF p_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
            RAISE EXCEPTION 'Invalid email address';
        END IF;

        -- Resolve-or-create by email. ON CONFLICT returns the EXISTING row's id;
        -- a fresh insert returns p_contact_id. Either way v_contact_id is the
        -- canonical id. We never touch the global name.
        INSERT INTO public.contact (id, email)
        VALUES (p_contact_id, lower(p_email))
        ON CONFLICT ON CONSTRAINT contact_email_unique
            DO UPDATE SET email = EXCLUDED.email
        RETURNING id INTO v_contact_id;
    ELSE
        v_contact_id := p_contact_id;
        IF NOT EXISTS (SELECT 1 FROM public.contact WHERE id = v_contact_id) THEN
            RAISE EXCEPTION 'Contact not found';
        END IF;
    END IF;

    -- Explicit per-user name override. source='user' is sticky vs connectors.
    INSERT INTO public.user_contact (user_id, contact_id, linked, source, name)
    VALUES (save_user_contact.user_id, v_contact_id, false, 'user', p_name)
    ON CONFLICT (user_id, contact_id)
        DO UPDATE SET
            name = EXCLUDED.name,
            source = 'user';

    RETURN QUERY
    SELECT * FROM "user"."actor" a
    WHERE a.user_id = save_user_contact.user_id
      AND a.id = v_contact_id;
END;
$function$;
```

- [ ] **Step 2: Generate and apply the migration**

```bash
cd libs/db
pnpm gen-migration -- add_save_user_contact
pnpm apply-migrations   # also runs `pnpm types`
```

Expected: a new file in `libs/db/migrations/`, applied cleanly, `src/types.ts` regenerated with a `save_user_contact` entry under the `user` Functions map.

- [ ] **Step 3: Verify schema/migration sync**

```bash
cd libs/db && pnpm diff-schema-migrations
```

Expected: no differences.

- [ ] **Step 4: Commit**

```bash
git add libs/db/schema/90-user-schema/83-save-user-contact.sql libs/db/migrations/ libs/db/src/types.ts
git commit -m "feat(db): user.save_user_contact for add/rename contact"
```

---

### Task 2: pgTAP tests for `save_user_contact`

**Files:**
- Create: `libs/db/tests/45-save-user-contact.sql`

Mirror the seeding idioms in `libs/db/tests/44-per-user-contact-name.sql`. `public.upsert_user_contact(user_id, user_email, user_name, avatar_url)` seeds a user's primary linked identity and returns its contact_id.

- [ ] **Step 1: Write the failing test**

Create `libs/db/tests/45-save-user-contact.sql`:

```sql
BEGIN;
SET LOCAL search_path = public, extensions;
SELECT plan(7);

CREATE TEMP TABLE _ids (k text PRIMARY KEY, v uuid);

DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    v_user2 uuid := gen_random_uuid();
    v_new_contact uuid := gen_random_uuid();
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'owner-45@example.test');
    INSERT INTO "public"."user" (id, email) VALUES (v_user2, 'other-45@example.test');
    -- Seed each user's own linked primary identity.
    PERFORM public.upsert_user_contact(v_user, 'owner-45@example.test', 'Owner', NULL);
    PERFORM public.upsert_user_contact(v_user2, 'other-45@example.test', 'Other', NULL);

    INSERT INTO _ids VALUES ('user', v_user), ('user2', v_user2), ('new_contact', v_new_contact);
END $$;

-- 1. ADD: brand-new email uses the client-provided id.
SELECT is(
    (SELECT (save_user_contact).id
     FROM "user".save_user_contact(
        (SELECT v FROM _ids WHERE k='user'),
        (SELECT v FROM _ids WHERE k='new_contact'),
        'newperson-45@example.test',
        'New Person'
     ) AS save_user_contact
     LIMIT 1),
    (SELECT v FROM _ids WHERE k='new_contact'),
    'ADD with a new email keeps the client-provided contact id'
);

-- 2. The contact is now visible in user.actor for the owner, with the per-user name.
SELECT is(
    (SELECT name FROM "user".actor
     WHERE user_id = (SELECT v FROM _ids WHERE k='user')
       AND id = (SELECT v FROM _ids WHERE k='new_contact')),
    'New Person',
    'ADD surfaces the contact in user.actor with the chosen name'
);

-- 3. The global contact.name was NOT written (per-user only).
SELECT is(
    (SELECT name FROM public.contact WHERE id = (SELECT v FROM _ids WHERE k='new_contact')),
    NULL,
    'ADD never writes the global contact.name'
);

-- 4. The other user does NOT see the contact (per-user address book).
SELECT is(
    (SELECT count(*)::int FROM "user".actor
     WHERE user_id = (SELECT v FROM _ids WHERE k='user2')
       AND id = (SELECT v FROM _ids WHERE k='new_contact')),
    0,
    'ADD is scoped to the calling user'
);

-- 5. ADD with an EXISTING email returns the existing contact id, not the client one.
DO $$
DECLARE
    v_existing uuid := gen_random_uuid();
BEGIN
    INSERT INTO public.contact (id, email, name)
        VALUES (v_existing, 'existing-45@example.test', 'Existing Global');
    INSERT INTO _ids VALUES ('existing', v_existing);
END $$;

SELECT is(
    (SELECT (save_user_contact).id
     FROM "user".save_user_contact(
        (SELECT v FROM _ids WHERE k='user'),
        gen_random_uuid(),               -- a DIFFERENT optimistic id
        'existing-45@example.test',
        'My Name For Them'
     ) AS save_user_contact
     LIMIT 1),
    (SELECT v FROM _ids WHERE k='existing'),
    'ADD with an existing email resolves to the existing contact id'
);

-- 6. RENAME (p_email NULL) sets the per-user override and is sticky vs connector longest-wins.
SELECT lives_ok(
    $$ SELECT "user".save_user_contact(
         (SELECT v FROM _ids WHERE k='user'),
         (SELECT v FROM _ids WHERE k='existing'),
         NULL,
         'Renamed' ) $$,
    'RENAME with NULL email succeeds'
);

SELECT is(
    (SELECT name FROM "user".actor
     WHERE user_id = (SELECT v FROM _ids WHERE k='user')
       AND id = (SELECT v FROM _ids WHERE k='existing')),
    'Renamed',
    'RENAME updates the per-user name override'
);

SELECT * FROM finish();
ROLLBACK;
```

- [ ] **Step 2: Run it to confirm it passes**

```bash
cd libs/db && pnpm test
```

Expected: `45-save-user-contact.sql` reports `ok 1..7`, all passing (the function exists from Task 1).

- [ ] **Step 3: Add a connector-longest-wins-stickiness assertion**

Append before `SELECT * FROM finish();` and bump `plan(7)` → `plan(8)`:

```sql
-- 8. A connector longest-wins write must NOT override the explicit user name.
SELECT public.upsert_user_contact_name(
    (SELECT v FROM _ids WHERE k='user'),
    (SELECT v FROM _ids WHERE k='existing'),
    'A Much Longer Connector Name'
);
SELECT is(
    (SELECT name FROM "user".actor
     WHERE user_id = (SELECT v FROM _ids WHERE k='user')
       AND id = (SELECT v FROM _ids WHERE k='existing')),
    'Renamed',
    'A connector longest-wins write does not override source=user'
);
```

- [ ] **Step 4: Run and commit**

```bash
cd libs/db && pnpm test
git add libs/db/tests/45-save-user-contact.sql
git commit -m "test(db): pgTAP for user.save_user_contact"
```

Expected: `ok 1..8` passing.

---

### Task 3: `user.save_group` function

**Files:**
- Create: `libs/db/schema/90-user-schema/84-save-group.sql`

- [ ] **Step 1: Write the function**

Create `libs/db/schema/90-user-schema/84-save-group.sql`:

```sql
-- Create or update a group from a single client row. Offline-queued via
-- POST /sync/groups. One upsert that diffs the incoming row against the DB:
--   * new id      -> CREATE (client-provided UUID; creator becomes admin; seed
--                    members from member_contact_ids). type defaults to private.
--   * existing id -> apply deltas:
--       - rename (admin-only),
--       - membership diff (only when the caller can see the full roster -- admins
--         always, open-group members otherwise -- because a private-group
--         non-admin's local roster is an empty array and would otherwise look
--         like "remove everyone"). Reuses public.add_group_members /
--         public.remove_group_members so join-policy authz is identical.
--   privacy/type changes on update are ignored.
-- Rejects auto_maintained groups. Returns the group id.
CREATE OR REPLACE FUNCTION "user".save_group (
    user_id uuid,
    p_group jsonb
)
    RETURNS uuid
    LANGUAGE plpgsql
    AS $function$
DECLARE
    v_group_id uuid := (p_group ->> 'id')::uuid;
    v_name text := p_group ->> 'name';
    v_privacy group_privacy := COALESCE((p_group ->> 'privacy')::group_privacy, 'open');
    v_member_ids uuid[] := COALESCE(
        (SELECT array_agg(value::uuid)
         FROM jsonb_array_elements_text(p_group -> 'member_contact_ids')),
        ARRAY[]::uuid[]);
    v_existing "group"%ROWTYPE;
    v_is_admin boolean;
    v_roster_visible boolean;
    v_to_add uuid[];
    v_to_remove uuid[];
BEGIN
    IF v_group_id IS NULL THEN
        RAISE EXCEPTION 'Group id is required';
    END IF;

    SELECT * INTO v_existing FROM "group" WHERE id = v_group_id;

    -- CREATE
    IF v_existing.id IS NULL THEN
        IF v_name IS NULL OR length(btrim(v_name)) = 0 THEN
            RAISE EXCEPTION 'Group name is required';
        END IF;

        INSERT INTO "group" (id, name, type, privacy, created_by)
        VALUES (v_group_id, v_name, 'private', v_privacy, save_group.user_id);

        INSERT INTO group_admin (group_id, user_id)
        VALUES (v_group_id, save_group.user_id);

        IF cardinality(v_member_ids) > 0 THEN
            INSERT INTO group_member (group_id, contact_id)
            SELECT v_group_id, unnest(v_member_ids)
            ON CONFLICT DO NOTHING;
        END IF;

        RETURN v_group_id;
    END IF;

    -- UPDATE
    IF v_existing.auto_maintained THEN
        RAISE EXCEPTION 'Cannot modify auto-maintained group';
    END IF;

    v_is_admin := EXISTS (
        SELECT 1 FROM group_admin
        WHERE group_id = v_group_id AND user_id = save_group.user_id);

    -- Rename (admin-only)
    IF v_name IS NOT NULL AND v_name IS DISTINCT FROM v_existing.name THEN
        IF NOT v_is_admin THEN
            RAISE EXCEPTION 'Only admins can rename this group';
        END IF;
        IF length(btrim(v_name)) = 0 THEN
            RAISE EXCEPTION 'Group name is required';
        END IF;
        UPDATE "group" SET name = v_name WHERE id = v_group_id;
    END IF;

    -- Membership diff, only for callers with an accurate local roster.
    v_roster_visible := v_is_admin OR (
        v_existing.privacy = 'open' AND EXISTS (
            SELECT 1 FROM group_member gm
            JOIN user_contact uc ON uc.contact_id = gm.contact_id
                AND uc.linked = TRUE AND uc.archived_at IS NULL
            WHERE gm.group_id = v_group_id AND uc.user_id = save_group.user_id));

    IF (p_group ? 'member_contact_ids') AND v_roster_visible THEN
        SELECT array_agg(c) INTO v_to_add
        FROM unnest(v_member_ids) c
        WHERE NOT EXISTS (
            SELECT 1 FROM group_member gm
            WHERE gm.group_id = v_group_id AND gm.contact_id = c);

        SELECT array_agg(gm.contact_id) INTO v_to_remove
        FROM group_member gm
        WHERE gm.group_id = v_group_id
          AND gm.contact_id <> ALL (v_member_ids);

        IF v_to_add IS NOT NULL AND cardinality(v_to_add) > 0 THEN
            PERFORM public.add_group_members(save_group.user_id, v_group_id, v_to_add);
        END IF;
        IF v_to_remove IS NOT NULL AND cardinality(v_to_remove) > 0 THEN
            PERFORM public.remove_group_members(save_group.user_id, v_group_id, v_to_remove);
        END IF;
    END IF;

    RETURN v_group_id;
END;
$function$;
```

- [ ] **Step 2: Generate, apply, verify**

```bash
cd libs/db
pnpm gen-migration -- add_save_group
pnpm apply-migrations
pnpm diff-schema-migrations   # expect no differences
```

- [ ] **Step 3: Commit**

```bash
git add libs/db/schema/90-user-schema/84-save-group.sql libs/db/migrations/ libs/db/src/types.ts
git commit -m "feat(db): user.save_group for create/rename/membership"
```

---

### Task 4: pgTAP tests for `save_group`

**Files:**
- Create: `libs/db/tests/46-save-group.sql`

Mirror the group seeding in `libs/db/tests/33-access-loss-group-removal.sql` (users + linked contacts via `upsert_user_contact`, a non-auto-maintained group, admin/member rows).

- [ ] **Step 1: Write the test**

Create `libs/db/tests/46-save-group.sql`:

```sql
BEGIN;
SET LOCAL search_path = public, extensions;
SELECT plan(6);

CREATE TEMP TABLE _ids (k text PRIMARY KEY, v uuid);

DO $$
DECLARE
    v_admin uuid := gen_random_uuid();
    v_member uuid := gen_random_uuid();
    v_member_contact uuid;
    v_group uuid := gen_random_uuid();
    v_extra_contact uuid := gen_random_uuid();
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_admin, 'admin-46@example.test');
    INSERT INTO "public"."user" (id, email) VALUES (v_member, 'member-46@example.test');
    PERFORM public.upsert_user_contact(v_admin, 'admin-46@example.test', 'Admin', NULL);
    v_member_contact := public.upsert_user_contact(v_member, 'member-46@example.test', 'Member', NULL);
    INSERT INTO public.contact (id, email, name)
        VALUES (v_extra_contact, 'extra-46@example.test', 'Extra');

    INSERT INTO _ids VALUES
        ('admin', v_admin), ('member', v_member),
        ('member_contact', v_member_contact),
        ('group', v_group), ('extra_contact', v_extra_contact);
END $$;

-- 1. CREATE with the client-provided id, seeding one member.
SELECT is(
    "user".save_group(
        (SELECT v FROM _ids WHERE k='admin'),
        jsonb_build_object(
            'id', (SELECT v FROM _ids WHERE k='group'),
            'name', 'My Group',
            'privacy', 'open',
            'member_contact_ids', jsonb_build_array((SELECT v FROM _ids WHERE k='member_contact'))
        )
    ),
    (SELECT v FROM _ids WHERE k='group'),
    'CREATE returns the client-provided group id'
);

-- 2. Creator is admin.
SELECT ok(
    EXISTS (SELECT 1 FROM group_admin
            WHERE group_id = (SELECT v FROM _ids WHERE k='group')
              AND user_id = (SELECT v FROM _ids WHERE k='admin')),
    'CREATE makes the creator an admin'
);

-- 3. Seeded member is present.
SELECT ok(
    EXISTS (SELECT 1 FROM group_member
            WHERE group_id = (SELECT v FROM _ids WHERE k='group')
              AND contact_id = (SELECT v FROM _ids WHERE k='member_contact')),
    'CREATE seeds the provided members'
);

-- 4. RENAME by a non-admin is rejected.
SELECT throws_ok(
    $$ SELECT "user".save_group(
         (SELECT v FROM _ids WHERE k='member'),
         jsonb_build_object(
            'id', (SELECT v FROM _ids WHERE k='group'),
            'name', 'Hijacked',
            'member_contact_ids', jsonb_build_array((SELECT v FROM _ids WHERE k='member_contact'))
         )) $$,
    'Only admins can rename this group',
    'RENAME by a non-admin is rejected'
);

-- 5. Admin adds a member via the full-set diff.
SELECT is(
    "user".save_group(
        (SELECT v FROM _ids WHERE k='admin'),
        jsonb_build_object(
            'id', (SELECT v FROM _ids WHERE k='group'),
            'name', 'My Group',
            'member_contact_ids', jsonb_build_array(
                (SELECT v FROM _ids WHERE k='member_contact'),
                (SELECT v FROM _ids WHERE k='extra_contact'))
        )
    ),
    (SELECT v FROM _ids WHERE k='group'),
    'membership diff add returns the group id'
);
SELECT ok(
    EXISTS (SELECT 1 FROM group_member
            WHERE group_id = (SELECT v FROM _ids WHERE k='group')
              AND contact_id = (SELECT v FROM _ids WHERE k='extra_contact')),
    'membership diff adds the new member'
);

SELECT * FROM finish();
ROLLBACK;
```

- [ ] **Step 2: Run and commit**

```bash
cd libs/db && pnpm test
git add libs/db/tests/46-save-group.sql
git commit -m "test(db): pgTAP for user.save_group"
```

Expected: `46-save-group.sql` reports `ok 1..6` passing.

---

# Part B — API (workers/api)

### Task 5: `POST /sync/actors`

**Files:**
- Modify: `workers/api/src/app/sync/actors.ts`

- [ ] **Step 1: Add imports and the POST handler**

In `workers/api/src/app/sync/actors.ts`, add to the imports at the top:

```ts
import { rpcUser } from "../../rpc";
import { notifyUserSync } from "./notify";
```

Then add this handler immediately before `export default actors;`:

```ts
// POST /sync/actors - Add or rename a contact in the user's address book.
// Only type==="contact" rows are writable (twist-instance actors are read-only).
// Body: { id, type, email?, name? }. Returns the canonical user.actor row so the
// client can reconcile its optimistic id with the server-owned (email-keyed) id.
actors.post("/sync/actors", async (c) => {
  const userId = c.var.user.id;
  const body = await c.req.json();

  if (body.type !== "contact") {
    return c.json({ error: "Only contacts can be saved" }, 400);
  }
  if (!body.id) {
    return c.json({ error: "id is required" }, 400);
  }

  try {
    const result = await withUserDb(c.var.db, userId, async (trx) => {
      return rpcUser(trx, "save_user_contact", {
        user_id: userId,
        p_contact_id: body.id,
        p_email: body.email ?? null,
        p_name: body.name ?? null,
      });
    });

    notifyUserSync(c, userId);
    return c.json(result as any);
  } catch (e: any) {
    // A RAISE EXCEPTION from the function surfaces as a Postgres error. Treat
    // these as client errors so the offline queue reverts the optimistic row
    // instead of retrying forever. (Mirror workers/api/src/app/group.ts.)
    if (e?.code === "P0001" || e?.cause?.code === "P0001") {
      return c.json({ error: e.message ?? "Request rejected" }, 400);
    }
    throw e;
  }
});
```

> Before finalizing the catch block, open `workers/api/src/app/group.ts` and match how it reads the Postgres error code (the Kysely error may nest the pg code on `e.cause`). Use the same accessor here.

- [ ] **Step 2: Lint**

```bash
cd workers/api && pnpm lint
```

Expected: no errors. If `rpcUser(trx, "save_user_contact", …)` errors with "not assignable", `src/types.ts` is stale — re-run `pnpm apply-migrations` in `libs/db` and re-lint.

- [ ] **Step 3: Commit**

```bash
git add workers/api/src/app/sync/actors.ts
git commit -m "feat(api): POST /sync/actors to add/rename a contact"
```

---

### Task 6: `POST /sync/groups`

**Files:**
- Modify: `workers/api/src/app/sync/groups.ts`

- [ ] **Step 1: Add imports and the POST handler**

In `workers/api/src/app/sync/groups.ts`, add to the imports:

```ts
import { rpcUser } from "../../rpc";
import { notifyUserSync } from "./notify";
```

Add before `export default groups;`:

```ts
// POST /sync/groups - Create or update a group from a single client row.
// Body: { id, name?, privacy?, member_contact_ids? }. The server diffs the row
// (create on a new id; rename admin-only; membership diff for roster-visible
// callers). Returns { id }.
groups.post("/sync/groups", async (c) => {
  const userId = c.var.user.id;
  const body = await c.req.json();

  if (!body.id) {
    return c.json({ error: "id is required" }, 400);
  }

  try {
    const groupId = await withUserDb(c.var.db, userId, async (trx) => {
      return rpcUser(trx, "save_group", {
        user_id: userId,
        p_group: {
          id: body.id,
          name: body.name ?? null,
          privacy: body.privacy ?? null,
          member_contact_ids: body.member_contact_ids ?? [],
        },
      });
    });

    notifyUserSync(c, userId);
    return c.json({ id: groupId } as any);
  } catch (e: any) {
    if (e?.code === "P0001" || e?.cause?.code === "P0001") {
      return c.json({ error: e.message ?? "Request rejected" }, 400);
    }
    throw e;
  }
});
```

- [ ] **Step 2: Lint**

```bash
cd workers/api && pnpm lint
```

- [ ] **Step 3: Commit**

```bash
git add workers/api/src/app/sync/groups.ts
git commit -m "feat(api): POST /sync/groups to create/rename/manage members"
```

---

### Task 7: Real-DB round-trip tests for both RPCs

**Files:**
- Create: `workers/api/src/app/sync/save-contact-group.test.ts`

This validates the `rpcUser` TS↔Postgres boundary (jsonb arg serialization, SETOF unwrap) that the handlers depend on. Mirror the txn-rollback harness in `workers/api/src/state/email-digest-query.test.ts`.

- [ ] **Step 1: Write the test**

Create `workers/api/src/app/sync/save-contact-group.test.ts`:

```ts
import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";

import { createDb, type DB } from "../../db";
import type { Bindings } from "../../env";
import { rpcUser } from "../../rpc";

const DATABASE_URL = process.env.DATABASE_URL;

class Rollback extends Error {}

/** Seed one user with a linked primary identity, run `fn`, then roll back. */
async function withUser<T>(
  fn: (trx: Kysely<DB>, userId: string) => Promise<T>,
): Promise<T> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  const userId = randomUUID();
  const email = `wf-${userId}@example.test`;
  let captured: T;
  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      await sql`INSERT INTO "user" (id, email) VALUES (${userId}::uuid, ${email})`.execute(trx);
      // upsert_user_contact seeds the user's primary linked contact.
      await sql`SELECT public.upsert_user_contact(${userId}::uuid, ${email}, 'Owner', NULL)`.execute(trx);
      captured = await fn(trx, userId);
      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }
  return captured!;
}

describe.skipIf(!DATABASE_URL)("save_user_contact via rpcUser", () => {
  it("adds a contact by email and returns the canonical actor row", async () => {
    const result = await withUser(async (trx, userId) => {
      const contactId = randomUUID();
      const row = await rpcUser(trx, "save_user_contact", {
        user_id: userId,
        p_contact_id: contactId,
        p_email: `added-${contactId}@example.test`,
        p_name: "Added Person",
      });
      return { contactId, row };
    });
    // Brand-new email -> client id preserved; per-user name returned.
    expect((result.row as any).id).toBe(result.contactId);
    expect((result.row as any).name).toBe("Added Person");
  });
});

describe.skipIf(!DATABASE_URL)("save_group via rpcUser", () => {
  it("creates a group with the client id and returns it", async () => {
    const groupId = await withUser(async (trx, userId) => {
      return rpcUser(trx, "save_group", {
        user_id: userId,
        p_group: { id: randomUUID(), name: "Test Group", privacy: "open", member_contact_ids: [] },
      });
    });
    expect(typeof groupId).toBe("string");
  });
});
```

> Note on the create test: we assert the returned id is a string rather than re-deriving the input id, because `withUser` generates the id inside the callback. If you want a strict equality check, lift the `randomUUID()` to a local before the `rpcUser` call and compare.

- [ ] **Step 2: Run the tests**

```bash
cd workers/api && pnpm test src/app/sync/save-contact-group.test.ts
```

Expected: 2 passing (or skipped if `DATABASE_URL` is unset — ensure your local DB is up and `DATABASE_URL` is exported; in a worktree use the `.worktree-db` port).

- [ ] **Step 3: Commit**

```bash
git add workers/api/src/app/sync/save-contact-group.test.ts
git commit -m "test(api): rpcUser round-trip for save_user_contact/save_group"
```

---

# Part C — Flutter (apps/plot)

> No Drift schema migration is needed: `Actors`/`Groups` already carry `pending` via the `SyncableTable` mixin. We only make them writable and add commands. Run `flutter analyze` after each task.

### Task 8: Make `Actors` writable + email-keyed reconciliation

**Files:**
- Modify: `apps/plot/lib/store/actor.dart`
- Modify: `apps/plot/lib/store/sync_orchestrator.dart`

- [ ] **Step 1: Implement `ActorsBase.toBase` and `processPulledRows`**

In `apps/plot/lib/store/actor.dart`, replace the `ActorsBase` class body. The current `toBase` throws; replace it and add `processPulledRows`:

```dart
class ActorsBase extends BaseTable {
  ActorsBase() : super(table: 'user_actor', syncEndpoint: 'actors');

  @override
  Map<String, dynamic> toBase(DataClass row) {
    // Only contacts are writable from the client (add/rename). The server
    // rejects any other type. We send the minimal payload save_user_contact
    // consumes; everything else on the row is server-derived.
    final actor = row as ActorRow;
    return {
      'id': actor.id.value.uuid,
      'type': 'contact',
      'email': actor.email,
      'name': actor.name,
    };
  }

  @override
  Insertable<ActorRow> fromBase(Map<String, dynamic> json) {
    return ActorRow.fromJson(json);
  }

  @override
  Future<List<Insertable<ActorRow>>> processPulledRows(
    Store store,
    Iterable<Insertable<ActorRow>> rows,
  ) async {
    // Contact id is server-owned (keyed on the globally-unique email). When the
    // server resolved an added email to an EXISTING contact, the optimistic row
    // AddContact inserted has a different id than the canonical row arriving
    // here. Email is unique server-side, so any LOCAL contact row with the same
    // email but a different id is a stale optimistic duplicate -- delete it
    // before this batch upserts the canonical row.
    final list = rows.toList();
    final tableName = store.actors.actualTableName;
    for (final r in list) {
      if (r is! ActorRow) continue;
      if (r.type != ActorType.contact || r.email == null) continue;
      await store.customStatement(
        'DELETE FROM $tableName WHERE lower(email) = lower(?) AND id != ?',
        [r.email, r.id.value.toBytes()],
      );
    }
    return list;
  }
}
```

> Verify the id accessors against `ActorIdConverter` in this file: `actor.id` is an `ActorId`. `actor.id.value` should be its `UuidValue` (`.uuid` → canonical string, `.toBytes()` → blob). If `ActorId` exposes these differently, adjust to the accessor that yields the 36-char string / `Uint8List`.

- [ ] **Step 2: Add `Actor.push`**

In `apps/plot/lib/store/actor.dart`, add a static method to the `Actor` class, next to `pull()`:

```dart
  static Future<bool> push() async {
    return Store.get.push(table, ActorsBase());
  }
```

- [ ] **Step 3: Flip the orchestrator `pushFn`**

In `apps/plot/lib/store/sync_orchestrator.dart`, change the `actor` entity:

```dart
  /// Actor entity. Contacts are writable (add/rename); other actor types are
  /// read-only and never get a pending flag, so push is a no-op for them.
  static final actor = SyncEntity(
    debugName: 'actor',
    dependsOn: [],
    pushFn: Actor.push,
    pullFn: Actor.pull,
  );
```

(`getEntityByTableName` already maps `'user_actor'` → `actor`, so `Store.save` will route the push correctly.)

- [ ] **Step 4: Analyze**

```bash
cd apps/plot && flutter analyze
```

Expected: no new errors.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/store/actor.dart apps/plot/lib/store/sync_orchestrator.dart
git commit -m "feat(app): make Actors writable with email-keyed reconciliation"
```

---

### Task 9: `AddContact` / `RenameContact` commands

**Files:**
- Create: `apps/plot/lib/command/contact.dart`

- [ ] **Step 1: Write the commands**

Create `apps/plot/lib/command/contact.dart`. Mirror the optimistic-write pattern from `command/priority.dart` (local write + `pending`, then orchestrator push via `Store.get.save`). After the local write we kick a pull so the canonical row (and any reconciliation) arrives promptly when online.

```dart
import 'package:drift/drift.dart';

import 'command.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/uuid.dart';
import 'package:plot/widget/widget.dart';

/// Add a new person to the user's address book by name + email.
class AddContact extends Command {
  AddContact({required this.name, required this.email})
    : super(
        title: 'Add contact',
        eventObject: EventObject.contact,
        eventAction: EventAction.added,
      );

  final String name;
  final String email;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final id = Uuid.generate();
    // Optimistic local row. The server uses this id when the email is new, so
    // no reconciliation is needed in the common case; ActorsBase.processPulledRows
    // collapses the rare same-email/different-id duplicate on the next pull.
    final companion = ActorsCompanion.insert(
      id: ActorId(id.value),
      type: ActorType.contact,
      self: false,
      name: Value(name),
      email: Value(email),
      pending: const Value(2),
    );
    await Store.get.save(Store.get.actors, companion, ActorsBase());
    // Fetch the canonical row (and reconcile) when online; offline this is a
    // no-op and the optimistic row stands until reconnect.
    unawaited(SyncOrchestrator.instance.pull(SyncOrchestrator.actor));
    return const CommandDone(message: 'Contact added');
  }
}

/// Rename a contact in the user's address book (per-user override).
class RenameContact extends Command {
  RenameContact({required this.contactId, required this.name})
    : super(
        title: 'Rename contact',
        eventObject: EventObject.contact,
        eventAction: EventAction.updated,
      );

  final ActorId contactId;
  final String name;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final existing = await Actor.getOne(contactId);
    if (existing == null) {
      return const CommandMessage('Contact not found', isError: true);
    }
    final updated = existing
        .toRow()
        .copyWith(name: Value(name), pending: const Value(2));
    await Store.get.save(Store.get.actors, updated.toCompanion(false), ActorsBase());
    return const CommandDone(message: 'Contact renamed');
  }
}
```

> Three things to verify against `actor.dart` while writing this:
> 1. `ActorsCompanion.insert` required vs optional fields — `type`, `self` are non-null columns (required); `name`/`email`/`pending` are `Value`-wrapped. Adjust the named args to the generated companion's signature.
> 2. `ActorId(id.value)` — construct an `ActorId` from a `UuidValue`; use whatever constructor `ActorIdConverter`/`ActorId` exposes (it may be `ActorId.fromUuid(...)` or similar).
> 3. The rename lookup + `.toRow()`/`.copyWith` — use the actual accessor that returns the underlying `ActorRow` for an in-store `Actor` (the file has an `Actor.fromStore` constructor and a cache; `Actor.getOne`/`Actor.fromCache` may already return an `ActorRow`-compatible object — if so call `.copyWith` directly and drop `.toRow()`).

If `EventObject.contact` doesn't exist in the analytics enum, add it (see `lib/analytics/`); otherwise reuse the closest existing object (`EventObject.activity` is the fallback used by group commands today).

- [ ] **Step 2: Analyze**

```bash
cd apps/plot && flutter analyze
```

Expected: no new errors. Fix accessor/companion mismatches flagged by the analyzer per the notes above.

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/command/contact.dart
git commit -m "feat(app): AddContact and RenameContact commands"
```

---

### Task 10: Make `Groups` writable

**Files:**
- Modify: `apps/plot/lib/store/group.dart`
- Modify: `apps/plot/lib/store/sync_orchestrator.dart`

- [ ] **Step 1: Implement `GroupsBase.toBase` and `Group.push`**

In `apps/plot/lib/store/group.dart`, replace the `GroupsBase.toBase` (currently throws) and add a `push` to `Group`:

```dart
class GroupsBase extends BaseTable {
  GroupsBase() : super(table: 'user_group', syncEndpoint: 'groups');

  @override
  Map<String, dynamic> toBase(DataClass row) {
    // Minimal payload save_group consumes. Computed columns (isAdmin, canPost,
    // ...) are server-derived and not sent.
    final group = row as GroupRow;
    return {
      'id': group.id.value.uuid,
      'name': group.name,
      'privacy': group.privacy,
      'member_contact_ids':
          group.memberContactIds?.map((u) => u.value.uuid).toList() ?? <String>[],
    };
  }

  @override
  Insertable<GroupRow> fromBase(Map<String, dynamic> json) {
    return GroupRow.fromJson(json);
  }
}
```

Add to the `Group` class, next to `pull()`:

```dart
  static Future<bool> push() async {
    return Store.get.push(table, GroupsBase());
  }
```

> Verify `group.id.value.uuid` and `u.value.uuid` against the `UuidConverter`/`UuidListConverter` in this file. `Uuid` is `extension type Uuid(UuidValue value)`, so `.value.uuid` yields the canonical string; adjust if the element type differs.

- [ ] **Step 2: Flip the orchestrator `pushFn`**

In `apps/plot/lib/store/sync_orchestrator.dart`, change the `group` entity:

```dart
  /// Group entity (writable: create / rename / membership).
  static final group = SyncEntity(
    debugName: 'group',
    dependsOn: [actor],
    pushFn: Group.push,
    pullFn: Group.pull,
  );
```

> Note: `dependsOn` was `[]`; set it to `[actor]` so a group push (which can carry new member contact ids) is ordered after the actor sync, consistent with how `priority` depends on `actor`.

- [ ] **Step 3: Analyze and commit**

```bash
cd apps/plot && flutter analyze
git add apps/plot/lib/store/group.dart apps/plot/lib/store/sync_orchestrator.dart
git commit -m "feat(app): make Groups writable for create/rename/membership"
```

---

### Task 11: Group commands — create, rename, migrate member add/remove to offline

**Files:**
- Modify: `apps/plot/lib/command/group.dart`

- [ ] **Step 1: Add `CreateGroup` and `RenameGroup`**

In `apps/plot/lib/command/group.dart`, add these classes (keep `ShareThreadWithGroups` unchanged — it posts to `/thread/:id/share`, a different endpoint out of this task's scope):

```dart
/// Create a new group.
class CreateGroup extends Command {
  CreateGroup({
    required this.name,
    this.privacy = 'open',
    this.memberContactIds = const [],
  }) : super(
          title: 'Create group',
          eventObject: EventObject.activity,
          eventAction: EventAction.added,
        );

  final String name;
  final String privacy;
  final List<Uuid> memberContactIds;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final companion = GroupsCompanion.insert(
      name: name,
      type: 'private',
      joinPolicy: 'member',
      privacy: Value(privacy),
      memberContactIds: Value(memberContactIds),
      // Optimistic: the creator is the admin; reconciled on next pull.
      isAdmin: const Value(true),
      canPost: const Value(true),
      canAddress: const Value(true),
      pending: const Value(2),
    );
    await Store.get.save(Store.get.groups, companion, GroupsBase());
    return const CommandDone(message: 'Group created');
  }
}

/// Rename an existing group (admin-only; enforced server-side).
class RenameGroup extends Command {
  RenameGroup({required this.groupId, required this.name})
    : super(
        title: 'Rename group',
        eventObject: EventObject.activity,
        eventAction: EventAction.updated,
      );

  final Uuid groupId;
  final String name;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final existing = Group.fromCache(groupId);
    if (existing == null) {
      return const CommandMessage('Group not found', isError: true);
    }
    final updated = existing.copyWith(name: name, pending: const Value(2));
    await Store.get.save(Store.get.groups, updated.toCompanion(false), GroupsBase());
    return const CommandDone(message: 'Group renamed');
  }
}
```

> Verify against `group.dart`/`store.dart`: `GroupsCompanion.insert` required args (`name`, `type`, `joinPolicy` are non-null text columns with no default → required; `privacy`/`memberContactIds`/`isAdmin`/… are `Value`-wrapped). `Group.fromCache(Uuid)` returns a `GroupRow?` (the cache map is `Map<Uuid, GroupRow>`). `GroupRow.copyWith` takes `name`/`pending`.

- [ ] **Step 2: Migrate `AddGroupMembers` / `RemoveGroupMembers` to offline writes**

Replace the bodies of the existing `AddGroupMembers` and `RemoveGroupMembers` `run()` methods so they update the local group's `memberContactIds` and `.save()` (offline-queued) instead of calling `api.post('/group/...')`. The server applies a full-set diff. The "You're offline" branch is removed.

Replace `AddGroupMembers.run`:

```dart
  @override
  Future<CommandReturn> run(BuildContext context) async {
    final existing = Group.fromCache(Uuid.fromString(groupId));
    if (existing == null) {
      return const CommandMessage('Group not found', isError: true);
    }
    final current = existing.memberContactIds ?? const <Uuid>[];
    final toAdd = contactIds.map(Uuid.fromString);
    final merged = {...current, ...toAdd}.toList();
    final updated = existing.copyWith(
      memberContactIds: Value(merged),
      pending: const Value(2),
    );
    await Store.get.save(Store.get.groups, updated.toCompanion(false), GroupsBase());
    return const CommandDone(message: 'Members added');
  }
```

Replace `RemoveGroupMembers.run`:

```dart
  @override
  Future<CommandReturn> run(BuildContext context) async {
    final existing = Group.fromCache(Uuid.fromString(groupId));
    if (existing == null) {
      return const CommandMessage('Group not found', isError: true);
    }
    final removing = contactIds.map(Uuid.fromString).toSet();
    final current = existing.memberContactIds ?? const <Uuid>[];
    final remaining = current.where((u) => !removing.contains(u)).toList();
    final updated = existing.copyWith(
      memberContactIds: Value(remaining),
      pending: const Value(2),
    );
    await Store.get.save(Store.get.groups, updated.toCompanion(false), GroupsBase());
    return const CommandDone(message: 'Members removed');
  }
```

Remove the now-unused `api`/`SyncOrchestrator.pull(group)`/`ApiException`/`NetworkException` imports from the file **only if** no remaining command in the file uses them (`ShareThreadWithGroups` still uses `api`, `ApiException`, `NetworkException` — keep those). Let `flutter analyze` tell you which imports are unused.

> `Uuid` equality: `memberContactIds` is `List<Uuid>` and `Uuid` is an extension type over `UuidValue`. The `{...current, ...toAdd}` set-dedup and `removing.contains(u)` rely on `UuidValue`'s `==`/`hashCode`. Verify in `util/uuid.dart` that extension-type `Uuid` forwards equality to `UuidValue` (it should, since extension types delegate to the representation). If set semantics misbehave, dedupe on `u.value.uuid` strings instead.

- [ ] **Step 3: Analyze**

```bash
cd apps/plot && flutter analyze
```

Expected: no new errors. The two existing call sites of `AddGroupMembers`/`RemoveGroupMembers` keep the same constructor signature (`groupId`, `contactIds`), so callers don't change.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/command/group.dart
git commit -m "feat(app): offline CreateGroup/RenameGroup + offline member add/remove"
```

---

### Task 12: Flutter test — email-keyed reconciliation

**Files:**
- Create: `apps/plot/test/store/actor_dedupe_test.dart`

- [ ] **Step 1: Write the test**

Create `apps/plot/test/store/actor_dedupe_test.dart`. Use an in-memory Drift database. The test inserts an optimistic contact row with a temp id, then runs the pulled canonical row (same email, different id) through `ActorsBase.processPulledRows` + an `insertOrReplace`, and asserts the temp row is gone and only the canonical row remains.

```dart
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/uuid.dart';

void main() {
  late Store store;

  setUp(() async {
    // Construct a Store backed by an in-memory executor. Use whatever test
    // constructor the project exposes (see other tests under test/store/).
    store = Store.forTesting(NativeDatabase.memory());
    await store.customStatement('PRAGMA foreign_keys = OFF');
  });

  tearDown(() async => store.close());

  test('processPulledRows removes a same-email optimistic temp row', () async {
    final tempId = Uuid.generate();
    final canonicalId = Uuid.generate();
    const email = 'dupe@example.test';

    // Optimistic temp row (as AddContact would write it).
    await store.add(
      store.actors,
      ActorsCompanion.insert(
        id: ActorId(tempId.value),
        type: ActorType.contact,
        self: false,
        email: const Value(email),
        name: const Value('Temp'),
        pending: const Value(2),
      ),
    );

    // Canonical row pulled from the server (different id, same email).
    final canonical = ActorRow.fromJson({
      'id': canonicalId.value.uuid,
      'type': 'contact',
      'email': email,
      'name': 'Canonical',
      'self': false,
      'inviteable': true,
      'primary': true,
      'external_accounts': '[]',
    });

    final base = ActorsBase();
    final processed = await base.processPulledRows(store, [canonical]);
    await store.batch((b) =>
        b.insertAll(store.actors, processed, mode: InsertMode.insertOrReplace));

    final rows = await store.select(store.actors).get();
    final emails = rows.where((r) => r.email == email).toList();
    expect(emails.length, 1, reason: 'temp duplicate should be deleted');
    expect(emails.single.id.value.uuid, canonicalId.value.uuid);
  });
}
```

> Verify the Store test constructor and `ActorRow.fromJson` field set against existing tests in `apps/plot/test/` (search for `Store.forTesting` or how other store tests build a `Store`). Adjust the `fromJson` map to include every non-nullable column `ActorRow.fromJson` requires (the analyzer/runtime will report missing keys). If the project has no `Store.forTesting`, follow the pattern the nearest existing store test uses to obtain a `Store` over `NativeDatabase.memory()`.

- [ ] **Step 2: Run the test**

```bash
cd apps/plot && flutter test test/store/actor_dedupe_test.dart
```

Expected: 1 passing.

- [ ] **Step 3: Commit**

```bash
git add apps/plot/test/store/actor_dedupe_test.dart
git commit -m "test(app): email-keyed contact reconciliation on pull"
```

---

# Finalization

### Task 13: Whole-feature checks

- [ ] **Step 1: DB checks**

```bash
cd libs/db && pnpm diff-schema-migrations && pnpm test && pnpm --filter @plotday/db run lint
```

Expected: no schema diff; all pgTAP green; types in sync.

- [ ] **Step 2: API checks**

```bash
cd workers/api && pnpm lint && pnpm test
```

Expected: lint clean; tests pass (DB-backed ones run when `DATABASE_URL` is set).

- [ ] **Step 3: Flutter checks**

```bash
cd apps/plot && flutter analyze && flutter test
```

Expected: no errors; tests pass.

- [ ] **Step 4: Run `/finalize`**

Run the `/finalize` skill checklist (lint, backwards-compat, error capture, docs, public submodule). Notes for this feature:
- **Backwards compat:** `/app/group.ts` endpoints are retained; no fields removed; new functions/handlers are additive (expand migration only — no contract migration needed). Old clients that never POST to `/sync/actors|groups` are unaffected.
- **Docs:** UI is out of scope, so hold the `docs/updates.md` / `docs/features.md` entries until the UI lands. (If asked to add user-facing notes now, skip — there's no user-visible surface yet.)
- **Public submodule:** no `public/` changes in this plan.

- [ ] **Step 5: Final commit (if `/finalize` made changes)**

```bash
git add -A && git commit -m "chore: finalize contacts/groups APIs"
```

---

## Self-review notes (addressed in this plan)

- **Spec coverage:** add contact (Task 1/9), rename contact (Task 1/9), group create+rename+membership (Task 3/11), offline via pending-queue (Tasks 8/10), `/sync` endpoints + `notifyUserSync` (Tasks 5/6), reconciliation (Task 8/12), per-user name isolation (asserted in Task 2 step 3 + the `save_user_contact` body), roster-visibility guard for membership (Task 3 + Task 4 implicit). Testing across all three layers (Tasks 2, 4, 7, 12).
- **Type consistency:** SQL param `user_id` (bare) used in every function and every `rpcUser` call; `save_user_contact` returns `SETOF "user"."actor"` (object row); `save_group` returns `uuid`; client `toBase` keys (`id`, `type`, `email`, `name` / `id`, `name`, `privacy`, `member_contact_ids`) match the handler body reads and the SQL `p_group ->>` extractions.
- **Known verify-points** (flagged inline, not placeholders): the exact `ActorId`/`Uuid` accessors and generated companion signatures must be confirmed against the actual Drift output while coding — these are codegen specifics the analyzer will pin down, not undecided design.
