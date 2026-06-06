# Groups & Topics — Plan 1: Topic DB Foundation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the database foundation for **topics** — Plot-only channels that own a thread stream, compose membership from contacts + groups (minus per-user opt-outs), and propagate membership changes (join/leave) to every thread in the topic — reusing the existing `group` → `thread_priority` propagation engine.

**Architecture:** A new `topic` cluster (`topic`, `topic_contact`, `topic_group`, `topic_admin`, `topic_member_optout`) plus a single `thread.topic_id` (≤1 topic per thread, no FK — mirrors `thread.twist_id` to avoid load-order coupling). Thread visibility gains a third path (`topic_id = ANY(user_topic_ids(user))`) alongside contacts and groups. A reusable access-path predicate `user.user_has_thread_access(user, thread)` backs every revoke decision so "lost my last path → revoke" is computed identically everywhere. The classifier routes a topic's stream via the existing `thread.topic` text convention (`'topic:'||topic_id`).

**Tech Stack:** PostgreSQL 18 (schema files in `libs/db/schema/`, Atlas migrations), pgTAP tests (`libs/db/tests/`, run via `pg_prove`).

**Design doc:** `docs/superpowers/specs/2026-06-05-groups-and-topics-design.md`

---

## Plan sequence (this is Plan 1 of 5)

1. **Topic DB foundation** ← this plan. Schema, membership, visibility, propagation. Testable via pgTAP.
2. **Group privacy** — `group_privacy` enum (`open`/`private`) + `can_address`; switch `user.group` gating from `type` to `privacy`; keep `type` for client compat.
3. **API + sync** — `/topic/*` routes, `/sync/topics`, group→contact snapshot-expansion helper, `upsert_thread` `topic_id` wiring in thread create, `user.topic_redacted` + topic-entity access-loss cleanup.
4. **Client store** — `TopicRow`, `GroupRow.privacy`, `ThreadRow.topicId`.
5. **Data migration** — Everyone → Plot Users; Plot Updates auto-maintained announce topic; onboarding repoint + backfill.

Each plan produces independently testable software. Plans 2–5 are written after the plan before them lands, so their code is grounded against the real schema.

## Execution prerequisites

- **Run in a worktree with an isolated DB.** Before starting: `bash scripts/worktree-db`, then verify `psql "$DATABASE_URL" -tAc "show port;"` prints the **worktree** port (not 54322). If `worktree-db` ran mid-session, override `DATABASE_URL` from `.worktree-db` on every DB command (see `libs/db/AGENTS.md`).
- **Standard DB task loop** (each task follows this):
  1. Write the pgTAP test file.
  2. Run it, expect FAIL: `cd libs/db && pg_prove -d "$DATABASE_URL" tests/<file>.sql`
  3. Edit schema files under `libs/db/schema/`.
  4. `cd libs/db && pnpm gen-migration -- <name>` then `pnpm apply-migrations` (regenerates `src/types.ts`).
  5. Re-run the pgTAP test, expect PASS.
  6. `pnpm diff-schema-migrations` → expect "no changes".
  7. Commit schema + migration + `src/types.ts` + test together.

---

## Task 1: Topic tables, enum, indexes, seq-bumps

**Files:**
- Create: `libs/db/schema/30-types/topic.sql`
- Create: `libs/db/schema/50-tables/29-topic.sql`
- Create: `libs/db/schema/95-triggers/28-topic_seq_bump.sql`
- Test: `libs/db/tests/50-topic-membership-seq.sql`

- [ ] **Step 1: Write the failing test** — `libs/db/tests/50-topic-membership-seq.sql`

```sql
-- topic cluster exists; membership writes bump topic.seq so /sync/topics
-- re-pulls the row (mirrors the group_member seq-bump invariant).
BEGIN;
SET LOCAL search_path = public, extensions;
SELECT plan(6);

SELECT has_table('public'::name, 'topic'::name, 'topic table exists');
SELECT has_table('public'::name, 'topic_contact'::name, 'topic_contact table exists');
SELECT has_table('public'::name, 'topic_group'::name, 'topic_group table exists');
SELECT has_table('public'::name, 'topic_admin'::name, 'topic_admin table exists');
SELECT has_table('public'::name, 'topic_member_optout'::name, 'topic_member_optout table exists');

DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    v_contact uuid;
    v_topic uuid := gen_random_uuid();
    v_seq_before xid8;
    v_seq_after xid8;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'topic50@test.local');
    v_contact := public.upsert_user_contact(v_user, 'topic50@test.local', 'T50', NULL);
    INSERT INTO public.topic (id, name, created_by) VALUES (v_topic, 'Topic 50', v_user);

    SELECT seq INTO v_seq_before FROM public.topic WHERE id = v_topic;
    INSERT INTO public.topic_contact (topic_id, contact_id) VALUES (v_topic, v_contact);
    SELECT seq INTO v_seq_after FROM public.topic WHERE id = v_topic;

    CREATE TEMP TABLE _seq50 (bumped boolean);
    INSERT INTO _seq50 VALUES (v_seq_after <> v_seq_before);
END $$;

SELECT ok((SELECT bumped FROM _seq50), 'topic_contact insert bumps topic.seq');

SELECT * FROM finish();
ROLLBACK;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd libs/db && pg_prove -d "$DATABASE_URL" tests/50-topic-membership-seq.sql`
Expected: FAIL — `relation "public.topic" does not exist`.

- [ ] **Step 3: Create the enum** — `libs/db/schema/30-types/topic.sql`

```sql
CREATE TYPE topic_join_policy AS ENUM (
    'open',   -- anyone can join or leave
    'admin'   -- only admins manage membership (reserved for team-scoped topics)
);
```

- [ ] **Step 4: Create the tables** — `libs/db/schema/50-tables/29-topic.sql`

```sql
CREATE TABLE "public"."topic" (
    "id" uuid PRIMARY KEY DEFAULT uuidv7 () NOT NULL,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "archived_at" timestamptz,
    "name" text NOT NULL,
    "created_by" uuid NOT NULL REFERENCES public."user" ("id") ON DELETE CASCADE,
    "team_id" bigint REFERENCES team ON DELETE SET NULL,
    -- Only admins may post threads to an announce topic (broadcast channels
    -- like Plot Updates). Receivers cannot post.
    "announce" boolean NOT NULL DEFAULT FALSE,
    "join_policy" topic_join_policy NOT NULL DEFAULT 'open',
    -- TRUE for system-managed topics (Plot Updates). Membership composition
    -- is maintained by triggers and cannot be modified via API.
    "auto_maintained" boolean NOT NULL DEFAULT FALSE,
    -- Stable identifier for system topics (e.g. '@plot.updates').
    "key" text,
    "seq" xid8 NOT NULL DEFAULT pg_current_xact_id(),
    CONSTRAINT topic_key_unique UNIQUE ("key")
);

CREATE INDEX idx_topic_seq ON "public"."topic" ("seq");
CREATE INDEX idx_topic_updated_at ON "public"."topic" ("updated_at");
CREATE INDEX idx_topic_team_id ON "public"."topic" ("team_id") WHERE team_id IS NOT NULL;
-- One auto-maintained global topic per key (Plot Updates singleton).
CREATE UNIQUE INDEX idx_topic_auto_global ON "public"."topic" ("key")
    WHERE auto_maintained = TRUE AND team_id IS NULL;

CREATE TRIGGER set_topic_updated_at
    BEFORE INSERT OR UPDATE ON "public"."topic"
    FOR EACH ROW EXECUTE FUNCTION update_seq_and_updated_at ();
CREATE TRIGGER set_topic_created_at
    BEFORE INSERT ON "public"."topic"
    FOR EACH ROW EXECUTE FUNCTION set_created_at ();

COMMENT ON TABLE "public"."topic" IS 'Plot-only channel that owns a stream of threads (thread.topic_id). Membership is composed from topic_contact + topic_group members, minus topic_member_optout. Adding a member retroactively grants access to every thread in the topic.';

CREATE TABLE "public"."topic_contact" (
    "topic_id" uuid NOT NULL REFERENCES topic ON DELETE CASCADE,
    "contact_id" uuid NOT NULL REFERENCES contact ON DELETE CASCADE,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY ("topic_id", "contact_id")
);
CREATE INDEX idx_topic_contact_contact_id ON "public"."topic_contact" ("contact_id");

CREATE TABLE "public"."topic_group" (
    "topic_id" uuid NOT NULL REFERENCES topic ON DELETE CASCADE,
    "group_id" uuid NOT NULL REFERENCES "group" ON DELETE CASCADE,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY ("topic_id", "group_id")
);
CREATE INDEX idx_topic_group_group_id ON "public"."topic_group" ("group_id");

CREATE TABLE "public"."topic_admin" (
    "topic_id" uuid NOT NULL REFERENCES topic ON DELETE CASCADE,
    "user_id" uuid NOT NULL REFERENCES public."user" ("id") ON DELETE CASCADE,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY ("topic_id", "user_id")
);
CREATE INDEX idx_topic_admin_user_id ON "public"."topic_admin" ("user_id");

-- Per-user "I left this topic". Overrides group-derived membership: the user
-- stops receiving the stream (existing + future) but still SEES the topic in
-- user.topic so they can rejoin. Distinct from removing them from a member group.
CREATE TABLE "public"."topic_member_optout" (
    "topic_id" uuid NOT NULL REFERENCES topic ON DELETE CASCADE,
    "user_id" uuid NOT NULL REFERENCES public."user" ("id") ON DELETE CASCADE,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY ("topic_id", "user_id")
);
CREATE INDEX idx_topic_member_optout_user_id ON "public"."topic_member_optout" ("user_id");
```

- [ ] **Step 5: Create the seq-bump triggers** — `libs/db/schema/95-triggers/28-topic_seq_bump.sql`

```sql
-- Bump topic.seq when membership/governance child rows change, so /sync/topics
-- (paginated on topic.seq) re-pulls the row and its computed user.topic columns.
-- Statement-level so a bulk write bumps each affected topic once. Mirrors the
-- group_member seq-bump in 24-group_auto_maintain.sql.
CREATE OR REPLACE FUNCTION public.bump_topic_seq_from_new_table ()
    RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    UPDATE "topic" SET updated_at = now()
    WHERE id IN (SELECT DISTINCT topic_id FROM new_table);
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.bump_topic_seq_from_old_table ()
    RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    UPDATE "topic" SET updated_at = now()
    WHERE id IN (SELECT DISTINCT topic_id FROM old_table);
    RETURN NULL;
END;
$$;

CREATE TRIGGER bump_topic_seq_on_contact_insert AFTER INSERT ON public.topic_contact
    REFERENCING NEW TABLE AS new_table FOR EACH STATEMENT
    EXECUTE FUNCTION public.bump_topic_seq_from_new_table ();
CREATE TRIGGER bump_topic_seq_on_contact_delete AFTER DELETE ON public.topic_contact
    REFERENCING OLD TABLE AS old_table FOR EACH STATEMENT
    EXECUTE FUNCTION public.bump_topic_seq_from_old_table ();
CREATE TRIGGER bump_topic_seq_on_group_insert AFTER INSERT ON public.topic_group
    REFERENCING NEW TABLE AS new_table FOR EACH STATEMENT
    EXECUTE FUNCTION public.bump_topic_seq_from_new_table ();
CREATE TRIGGER bump_topic_seq_on_group_delete AFTER DELETE ON public.topic_group
    REFERENCING OLD TABLE AS old_table FOR EACH STATEMENT
    EXECUTE FUNCTION public.bump_topic_seq_from_old_table ();
CREATE TRIGGER bump_topic_seq_on_admin_insert AFTER INSERT ON public.topic_admin
    REFERENCING NEW TABLE AS new_table FOR EACH STATEMENT
    EXECUTE FUNCTION public.bump_topic_seq_from_new_table ();
CREATE TRIGGER bump_topic_seq_on_admin_delete AFTER DELETE ON public.topic_admin
    REFERENCING OLD TABLE AS old_table FOR EACH STATEMENT
    EXECUTE FUNCTION public.bump_topic_seq_from_old_table ();
CREATE TRIGGER bump_topic_seq_on_optout_insert AFTER INSERT ON public.topic_member_optout
    REFERENCING NEW TABLE AS new_table FOR EACH STATEMENT
    EXECUTE FUNCTION public.bump_topic_seq_from_new_table ();
CREATE TRIGGER bump_topic_seq_on_optout_delete AFTER DELETE ON public.topic_member_optout
    REFERENCING OLD TABLE AS old_table FOR EACH STATEMENT
    EXECUTE FUNCTION public.bump_topic_seq_from_old_table ();
```

- [ ] **Step 6: Generate + apply migration**

Run: `cd libs/db && pnpm gen-migration -- add_topic_cluster && pnpm apply-migrations`
Expected: migration created and applied; `src/types.ts` regenerated with the new tables.

- [ ] **Step 7: Run test to verify it passes**

Run: `cd libs/db && pg_prove -d "$DATABASE_URL" tests/50-topic-membership-seq.sql`
Expected: PASS (6/6).

- [ ] **Step 8: Verify schema/migration sync**

Run: `cd libs/db && pnpm diff-schema-migrations`
Expected: no changes.

- [ ] **Step 9: Commit**

```bash
git add libs/db/schema/30-types/topic.sql libs/db/schema/50-tables/29-topic.sql \
        libs/db/schema/95-triggers/28-topic_seq_bump.sql \
        libs/db/tests/50-topic-membership-seq.sql \
        libs/db/migrations/ libs/db/src/types.ts
git commit -m "feat(db): topic cluster tables + seq-bump triggers"
```

---

## Task 2: `thread.topic_id` column + `upsert_thread` routing string

**Files:**
- Modify: `libs/db/schema/50-tables/24-thread.sql` (add column + index after `twist_id`, ~line 34)
- Modify: `libs/db/schema/90-user-schema/80-upsert_thread.sql`
- Test: `libs/db/tests/51-thread-topic-routing.sql`

- [ ] **Step 1: Write the failing test** — `libs/db/tests/51-thread-topic-routing.sql`

```sql
-- A user-authored thread created with topic_id gets topic = 'topic:'||topic_id
-- so the classifier's topic short-circuit groups the whole stream.
BEGIN;
SET LOCAL search_path = public, extensions;
SELECT plan(2);

DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    v_topic uuid := gen_random_uuid();
    v_thread thread;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'topic51@test.local');
    PERFORM public.upsert_user_contact(v_user, 'topic51@test.local', 'T51', NULL);
    INSERT INTO public.topic (id, name, created_by) VALUES (v_topic, 'Topic 51', v_user);

    v_thread := "user".upsert_thread(
        v_user,
        jsonb_build_object('title', 'Hello topic', 'topic_id', v_topic::text)
    );

    CREATE TEMP TABLE _t51 (topic_id uuid, topic text);
    INSERT INTO _t51 VALUES (v_thread.topic_id, v_thread.topic);
END $$;

SELECT is((SELECT topic_id FROM _t51), (SELECT topic_id FROM _t51), 'thread.topic_id is set');
SELECT is(
    (SELECT topic FROM _t51),
    'topic:' || (SELECT topic_id FROM _t51)::text,
    'thread.topic derived as topic:<id>'
);

SELECT * FROM finish();
ROLLBACK;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd libs/db && pg_prove -d "$DATABASE_URL" tests/51-thread-topic-routing.sql`
Expected: FAIL — `column "topic_id" of relation "thread" does not exist`.

- [ ] **Step 3: Add the column** — in `libs/db/schema/50-tables/24-thread.sql`, after the `twist_id` column (~line 34), add:

```sql
    -- The topic (channel) this thread belongs to. ≤1 per thread, giving the
    -- thread a single stable routing string. FK intentionally omitted (mirrors
    -- twist_id) to avoid load-order coupling with the topic table, which is
    -- defined after thread in schema order. Visibility flows through topic
    -- membership (see user_topic_ids); ad-hoc extra recipients still go in
    -- contacts/groups.
    "topic_id" uuid,
```

And add an index alongside the other thread indexes (near `idx_thread_topic`, ~line 136):

```sql
CREATE INDEX idx_thread_topic_id ON "public"."thread" ("topic_id") WHERE topic_id IS NOT NULL;
```

- [ ] **Step 4: Wire `topic_id` into `upsert_thread`** — `libs/db/schema/90-user-schema/80-upsert_thread.sql`. Four edits:

(a) Add a declaration after `v_input_topic text;` (~line 60):

```sql
    -- Input topic_id — the channel the thread belongs to.
    v_input_topic_id uuid;
```

(b) Extract it next to `v_input_topic` (after line 257):

```sql
    v_input_topic_id := COALESCE((p_thread ->> 'topic_id')::uuid, (p_defaults ->> 'topic_id')::uuid);
```

(c) Replace the INSERT-path topic derivation block (lines 274–291) with one that prefers an explicit `topic_id`:

```sql
    IF v_existing.id IS NULL AND v_input_topic IS NULL THEN
        IF v_input_topic_id IS NOT NULL THEN
            -- A topic-addressed thread routes by its channel, stable across
            -- the whole stream, so the classifier topic short-circuit groups
            -- the user's moves of any one thread onto all the others.
            v_resolved_topic := 'topic:' || v_input_topic_id::text;
        ELSIF v_twist_id IS NULL THEN
            SELECT
                COALESCE(
                    p.config ->> 'topic',
                    CASE WHEN nlevel(p.path) > 1 THEN p.id::text END
                )
            INTO v_resolved_topic
            FROM public.priority p
            WHERE p.id = v_priority_id;

            IF v_resolved_topic IS NULL AND cardinality(v_input_groups) > 0 THEN
                v_resolved_topic := v_input_groups[1]::text;
            END IF;
        END IF;
    ELSE
        v_resolved_topic := v_input_topic;
    END IF;
```

(d) Add `topic_id` to the INSERT column list and ON CONFLICT update. In the INSERT column list (line 360) add `topic_id` after `topic`:

```sql
        draft, key, icon, twist_id, pending_contacts, team_id, embedding, topic_id
```

In the VALUES list, after the `embedding` value (line 405) add:

```sql
        ,
        -- topic_id: the channel this thread belongs to (immutable-ish; only
        -- re-set on the archived-refile path below).
        v_input_topic_id
```

In the `ON CONFLICT (id) DO UPDATE SET` block, after the `embedding = …` clause (line 546), add:

```sql
            ,
            topic_id = CASE WHEN v_is_archived THEN
                v_input_topic_id
            ELSE
                CASE WHEN p_thread ? 'topic_id' THEN v_input_topic_id ELSE thread.topic_id END
            END
```

- [ ] **Step 5: Generate + apply migration**

Run: `cd libs/db && pnpm gen-migration -- add_thread_topic_id && pnpm apply-migrations`
Expected: applied; `topic_id` added to `thread`; `src/types.ts` updated.

- [ ] **Step 6: Run test to verify it passes**

Run: `cd libs/db && pg_prove -d "$DATABASE_URL" tests/51-thread-topic-routing.sql`
Expected: PASS (2/2).

- [ ] **Step 7: Verify sync + commit**

```bash
cd libs/db && pnpm diff-schema-migrations   # expect no changes
git add libs/db/schema/50-tables/24-thread.sql libs/db/schema/90-user-schema/80-upsert_thread.sql \
        libs/db/tests/51-thread-topic-routing.sql libs/db/migrations/ libs/db/src/types.ts
git commit -m "feat(db): thread.topic_id + topic routing string in upsert_thread"
```

---

## Task 3: `user.user_topic_ids` — effective membership

**Files:**
- Create: `libs/db/schema/90-user-schema/08-user_topic_ids.sql`
- Test: `libs/db/tests/52-user-topic-ids.sql`

- [ ] **Step 1: Write the failing test** — `libs/db/tests/52-user-topic-ids.sql`

```sql
-- Effective topic membership: direct contact OR via an included group,
-- minus per-user opt-outs. Admins also count.
BEGIN;
SET LOCAL search_path = public, extensions;
SELECT plan(5);

CREATE TEMP TABLE _t52 (
    u_direct uuid, u_viagroup uuid, u_optout uuid, u_none uuid,
    topic_id uuid
);

DO $$
DECLARE
    v_direct uuid := gen_random_uuid();
    v_viagroup uuid := gen_random_uuid();
    v_optout uuid := gen_random_uuid();
    v_none uuid := gen_random_uuid();
    c_direct uuid; c_viagroup uuid; c_optout uuid; c_none uuid;
    v_group uuid := gen_random_uuid();
    v_topic uuid := gen_random_uuid();
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES
        (v_direct, 'd52@test.local'), (v_viagroup, 'g52@test.local'),
        (v_optout, 'o52@test.local'), (v_none, 'n52@test.local');
    c_direct  := public.upsert_user_contact(v_direct, 'd52@test.local', 'D', NULL);
    c_viagroup:= public.upsert_user_contact(v_viagroup, 'g52@test.local', 'G', NULL);
    c_optout  := public.upsert_user_contact(v_optout, 'o52@test.local', 'O', NULL);
    c_none    := public.upsert_user_contact(v_none, 'n52@test.local', 'N', NULL);

    INSERT INTO public."group" (id, name, type, created_by) VALUES (v_group, 'G52', 'public', v_direct);
    INSERT INTO public.group_member (group_id, contact_id) VALUES
        (v_group, c_viagroup), (v_group, c_optout);

    INSERT INTO public.topic (id, name, created_by) VALUES (v_topic, 'T52', v_direct);
    INSERT INTO public.topic_contact (topic_id, contact_id) VALUES (v_topic, c_direct);
    INSERT INTO public.topic_group (topic_id, group_id) VALUES (v_topic, v_group);
    -- c_optout is a member via the group, but opts out.
    INSERT INTO public.topic_member_optout (topic_id, user_id) VALUES (v_topic, v_optout);

    INSERT INTO _t52 VALUES (v_direct, v_viagroup, v_optout, v_none, v_topic);
END $$;

SELECT ok((SELECT topic_id FROM _t52) = ANY("user".user_topic_ids((SELECT u_direct FROM _t52))),
    'direct contact member is in user_topic_ids');
SELECT ok((SELECT topic_id FROM _t52) = ANY("user".user_topic_ids((SELECT u_viagroup FROM _t52))),
    'group-derived member is in user_topic_ids');
SELECT ok(NOT ((SELECT topic_id FROM _t52) = ANY("user".user_topic_ids((SELECT u_optout FROM _t52)))),
    'opted-out user is excluded from user_topic_ids');
SELECT ok(NOT ((SELECT topic_id FROM _t52) = ANY("user".user_topic_ids((SELECT u_none FROM _t52)))),
    'non-member is excluded from user_topic_ids');
SELECT ok(cardinality("user".user_topic_ids(gen_random_uuid())) = 0,
    'unknown user yields empty array');

SELECT * FROM finish();
ROLLBACK;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd libs/db && pg_prove -d "$DATABASE_URL" tests/52-user-topic-ids.sql`
Expected: FAIL — `function user.user_topic_ids(uuid) does not exist`.

- [ ] **Step 3: Create the function** — `libs/db/schema/90-user-schema/08-user_topic_ids.sql`

```sql
-- Topics the user is an EFFECTIVE member of: a direct contact member, a
-- member via an included group, or an admin — minus per-user opt-outs.
-- Mirrors user.user_group_ids. Used by user.thread visibility and
-- user.user_has_thread_access.
CREATE OR REPLACE FUNCTION "user".user_topic_ids (p_user_id uuid)
    RETURNS uuid[]
    LANGUAGE sql
    STABLE
    AS $$
    SELECT COALESCE(array_agg(DISTINCT t.id), ARRAY[]::uuid[])
    FROM topic t
    WHERE t.archived_at IS NULL
      AND NOT EXISTS (
          SELECT 1 FROM topic_member_optout o
          WHERE o.topic_id = t.id AND o.user_id = p_user_id
      )
      AND (
          EXISTS (
              SELECT 1 FROM topic_contact tc
              JOIN user_contact uc ON uc.contact_id = tc.contact_id
                  AND uc.linked = TRUE AND uc.archived_at IS NULL
              WHERE tc.topic_id = t.id AND uc.user_id = p_user_id
          )
          OR EXISTS (
              SELECT 1 FROM topic_group tg
              JOIN group_member gm ON gm.group_id = tg.group_id
              JOIN user_contact uc ON uc.contact_id = gm.contact_id
                  AND uc.linked = TRUE AND uc.archived_at IS NULL
              WHERE tg.topic_id = t.id AND uc.user_id = p_user_id
          )
          OR EXISTS (
              SELECT 1 FROM topic_admin ta
              WHERE ta.topic_id = t.id AND ta.user_id = p_user_id
          )
      );
$$;
```

- [ ] **Step 4: Apply (function-only — still via migration)**

Run: `cd libs/db && pnpm gen-migration -- add_user_topic_ids && pnpm apply-migrations`

- [ ] **Step 5: Run test to verify it passes**

Run: `cd libs/db && pg_prove -d "$DATABASE_URL" tests/52-user-topic-ids.sql`
Expected: PASS (5/5).

- [ ] **Step 6: Verify sync + commit**

```bash
cd libs/db && pnpm diff-schema-migrations   # expect no changes
git add libs/db/schema/90-user-schema/08-user_topic_ids.sql \
        libs/db/tests/52-user-topic-ids.sql libs/db/migrations/ libs/db/src/types.ts
git commit -m "feat(db): user.user_topic_ids effective-membership function"
```

---

## Task 4: `user.thread` topic visibility + `topic_id` column + `user.topic` view

**Files:**
- Modify: `libs/db/schema/90-user-schema/30-thread.sql` (add `topic_id` to `user.thread` SELECT + WHERE; add `NULL::uuid AS topic_id` to `user.thread_redacted`)
- Create: `libs/db/schema/90-user-schema/37-topic.sql`
- Test: `libs/db/tests/53-topic-thread-visibility.sql`

- [ ] **Step 1: Write the failing test** — `libs/db/tests/53-topic-thread-visibility.sql`

```sql
-- A thread with topic_id is visible (via user.thread) to effective topic
-- members and NOT to opted-out users; user.topic shows the topic to members
-- AND opted-out users (so they can rejoin).
BEGIN;
SET LOCAL search_path = public, extensions;
SELECT plan(5);

CREATE TEMP TABLE _t53 (member uuid, optout uuid, outsider uuid, topic_id uuid, thread_id uuid);

DO $$
DECLARE
    v_author uuid := gen_random_uuid();
    v_member uuid := gen_random_uuid();
    v_optout uuid := gen_random_uuid();
    v_outsider uuid := gen_random_uuid();
    c_author uuid; c_member uuid; c_optout uuid;
    v_topic uuid := gen_random_uuid();
    v_thread thread;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES
        (v_author,'a53@test.local'),(v_member,'m53@test.local'),
        (v_optout,'o53@test.local'),(v_outsider,'x53@test.local');
    c_author := public.upsert_user_contact(v_author,'a53@test.local','A',NULL);
    c_member := public.upsert_user_contact(v_member,'m53@test.local','M',NULL);
    c_optout := public.upsert_user_contact(v_optout,'o53@test.local','O',NULL);
    PERFORM public.upsert_user_contact(v_outsider,'x53@test.local','X',NULL);

    INSERT INTO public.topic (id, name, created_by) VALUES (v_topic, 'T53', v_author);
    INSERT INTO public.topic_contact (topic_id, contact_id) VALUES
        (v_topic, c_member), (v_topic, c_optout);
    INSERT INTO public.topic_member_optout (topic_id, user_id) VALUES (v_topic, v_optout);

    -- Author posts a thread to the topic. (Task 5's trigger files peers; here
    -- we only need the author's create to set topic_id + routing.)
    v_thread := "user".upsert_thread(v_author,
        jsonb_build_object('title','Topic thread 53','topic_id', v_topic::text));

    -- Settle the member's auto-filed peer row so the classify window passes.
    UPDATE public.thread_priority tp
       SET priority_id = (SELECT id FROM public.priority WHERE user_id = v_member LIMIT 1),
           classify_at = NULL
     WHERE thread_id = v_thread.id AND user_id = v_member;

    INSERT INTO _t53 VALUES (v_member, v_optout, v_outsider, v_topic, v_thread.id);
END $$;

SELECT ok(EXISTS (SELECT 1 FROM "user".thread ut, _t53
    WHERE ut.user_id = _t53.member AND ut.id = _t53.thread_id),
    'member sees the topic thread via user.thread');
SELECT ok(NOT EXISTS (SELECT 1 FROM "user".thread ut, _t53
    WHERE ut.user_id = _t53.optout AND ut.id = _t53.thread_id),
    'opted-out user does NOT see the topic thread');
SELECT ok(NOT EXISTS (SELECT 1 FROM "user".thread ut, _t53
    WHERE ut.user_id = _t53.outsider AND ut.id = _t53.thread_id),
    'outsider does NOT see the topic thread');
SELECT ok(EXISTS (SELECT 1 FROM "user".topic vt, _t53
    WHERE vt.user_id = _t53.member AND vt.id = _t53.topic_id AND vt.is_member),
    'member sees topic in user.topic with is_member=true');
SELECT ok(EXISTS (SELECT 1 FROM "user".topic vt, _t53
    WHERE vt.user_id = _t53.optout AND vt.id = _t53.topic_id AND vt.opted_out AND NOT vt.is_member),
    'opted-out user still sees topic (opted_out=true, is_member=false) to rejoin');

SELECT * FROM finish();
ROLLBACK;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd libs/db && pg_prove -d "$DATABASE_URL" tests/53-topic-thread-visibility.sql`
Expected: FAIL — `relation "user.topic" does not exist` (and member visibility fails: topic path not yet in `user.thread`).

- [ ] **Step 3: Extend `user.thread`** — in `libs/db/schema/90-user-schema/30-thread.sql`:

Add `a.topic_id,` to the SELECT list, right after `a.topic,` (line 60):

```sql
    a.topic,
    a.topic_id,
```

Replace the visibility OR-block (lines 198–201) with:

```sql
    AND (
        a.contacts && "user".user_contact_ids(tp.user_id)
        OR a.groups && "user".user_group_ids(tp.user_id)
        OR (a.topic_id IS NOT NULL AND a.topic_id = ANY("user".user_topic_ids(tp.user_id)))
    )
```

In `user.thread_redacted`, add a NULL topic_id right after the `NULL::text AS topic,` line (line 272) so both views share a shape:

```sql
    NULL::text AS topic,
    NULL::uuid AS topic_id,
```

- [ ] **Step 4: Create `user.topic`** — `libs/db/schema/90-user-schema/37-topic.sql`

```sql
-- Per-user topic read-model. Visible to members, admins, AND opted-out users
-- (so they can rejoin). member_contact_ids mirrors the user.group announce
-- gating: full composed roster for admins / non-announce members; empty for
-- announce-topic non-admins. (Fine-grained per-member-group privacy lands in
-- Plan 2.)
CREATE OR REPLACE VIEW "user"."topic"
AS
SELECT
    u.id AS user_id,
    t.id,
    t.created_at,
    t.updated_at,
    t.seq,
    t.archived_at,
    t.name,
    t.team_id,
    t.announce,
    t.join_policy,
    t.auto_maintained,
    t.key,
    EXISTS (SELECT 1 FROM topic_admin ta WHERE ta.topic_id = t.id AND ta.user_id = u.id) AS is_admin,
    (t.id = ANY("user".user_topic_ids(u.id))) AS is_member,
    EXISTS (SELECT 1 FROM topic_member_optout o WHERE o.topic_id = t.id AND o.user_id = u.id) AS opted_out,
    -- can_post: admins always; non-admins only when not announce and a member.
    (
        EXISTS (SELECT 1 FROM topic_admin ta WHERE ta.topic_id = t.id AND ta.user_id = u.id)
        OR (t.announce = FALSE AND t.id = ANY("user".user_topic_ids(u.id)))
    ) AS can_post,
    -- can_manage: admins always; or open join_policy member.
    (
        EXISTS (SELECT 1 FROM topic_admin ta WHERE ta.topic_id = t.id AND ta.user_id = u.id)
        OR (t.join_policy = 'open' AND t.id = ANY("user".user_topic_ids(u.id)))
    ) AS can_manage,
    CASE
        WHEN EXISTS (SELECT 1 FROM topic_admin ta WHERE ta.topic_id = t.id AND ta.user_id = u.id)
             OR (t.announce = FALSE AND t.id = ANY("user".user_topic_ids(u.id)))
        THEN (
            SELECT COALESCE(array_agg(DISTINCT cid), ARRAY[]::uuid[])
            FROM (
                SELECT tc.contact_id AS cid FROM topic_contact tc WHERE tc.topic_id = t.id
                UNION
                SELECT gm.contact_id FROM topic_group tg
                    JOIN group_member gm ON gm.group_id = tg.group_id
                    WHERE tg.topic_id = t.id
            ) roster
        )
        ELSE ARRAY[]::uuid[]
    END AS member_contact_ids
FROM
    public."user" u
    CROSS JOIN topic t
WHERE
    t.archived_at IS NULL
    AND (
        t.id = ANY("user".user_topic_ids(u.id))                              -- member
        OR EXISTS (SELECT 1 FROM topic_member_optout o
                   WHERE o.topic_id = t.id AND o.user_id = u.id)             -- opted-out (can rejoin)
        OR EXISTS (SELECT 1 FROM topic_admin ta
                   WHERE ta.topic_id = t.id AND ta.user_id = u.id)          -- admin
    );
```

- [ ] **Step 5: Apply migration**

Run: `cd libs/db && pnpm gen-migration -- add_user_topic_view_and_thread_topic_id && pnpm apply-migrations`

- [ ] **Step 6: Run test to verify it passes**

Run: `cd libs/db && pg_prove -d "$DATABASE_URL" tests/53-topic-thread-visibility.sql`
Expected: PASS (5/5).

> Note: this task depends on Task 5's peer-filing trigger for the member to have a `thread_priority` row. If running tasks in order, Task 5 lands the trigger; if this test fails only on the member-visibility assertion before Task 5, that is expected — re-run after Task 5. To keep Task 4 self-contained, the test above settles the member's row directly, but the row only exists once Task 5's `file_thread_priority_for_topic_members` trigger fires on the author's `upsert_thread`. **Sequence Task 5 before re-running this test**, or temporarily insert the member's `thread_priority` row in the DO block.

- [ ] **Step 7: Verify sync + bump existing thread rows (new view column) + commit**

The migration adds `topic_id` to `user.thread`; existing thread rows need a seq bump so clients re-pull. Add to the generated migration file, at the end:

```sql
UPDATE public.thread SET updated_at = now() WHERE archived_at IS NULL;
```

Then:

```bash
cd libs/db && pnpm apply-migrations && pnpm diff-schema-migrations   # expect no changes
git add libs/db/schema/90-user-schema/30-thread.sql libs/db/schema/90-user-schema/37-topic.sql \
        libs/db/tests/53-topic-thread-visibility.sql libs/db/migrations/ libs/db/src/types.ts
git commit -m "feat(db): topic thread visibility + user.topic read-model"
```

---

## Task 5: `file_thread_priority_for_topic_members` — peer filing on `thread.topic_id`

**Files:**
- Create: `libs/db/schema/95-triggers/29-thread_topic_peers.sql`
- Test: `libs/db/tests/54-topic-peer-filing.sql`

- [ ] **Step 1: Write the failing test** — `libs/db/tests/54-topic-peer-filing.sql`

```sql
-- When a thread gains a topic_id, every effective topic member (other than
-- the author) gets a pending thread_priority + thread_state row.
BEGIN;
SET LOCAL search_path = public, extensions;
SELECT plan(3);

CREATE TEMP TABLE _t54 (member uuid, optout uuid, thread_id uuid);

DO $$
DECLARE
    v_author uuid := gen_random_uuid();
    v_member uuid := gen_random_uuid();
    v_optout uuid := gen_random_uuid();
    c_author uuid; c_member uuid; c_optout uuid;
    v_topic uuid := gen_random_uuid();
    v_thread thread;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES
        (v_author,'a54@test.local'),(v_member,'m54@test.local'),(v_optout,'o54@test.local');
    c_author := public.upsert_user_contact(v_author,'a54@test.local','A',NULL);
    c_member := public.upsert_user_contact(v_member,'m54@test.local','M',NULL);
    c_optout := public.upsert_user_contact(v_optout,'o54@test.local','O',NULL);

    INSERT INTO public.topic (id, name, created_by) VALUES (v_topic, 'T54', v_author);
    INSERT INTO public.topic_contact (topic_id, contact_id) VALUES
        (v_topic, c_member), (v_topic, c_optout);
    INSERT INTO public.topic_member_optout (topic_id, user_id) VALUES (v_topic, v_optout);

    v_thread := "user".upsert_thread(v_author,
        jsonb_build_object('title','Peer filing 54','topic_id', v_topic::text));

    INSERT INTO _t54 VALUES (v_member, v_optout, v_thread.id);
END $$;

SELECT ok(EXISTS (SELECT 1 FROM thread_priority tp, _t54
    WHERE tp.thread_id = _t54.thread_id AND tp.user_id = _t54.member),
    'effective topic member gets a thread_priority row');
SELECT ok(EXISTS (SELECT 1 FROM thread_state ts, _t54
    WHERE ts.thread_id = _t54.thread_id AND ts.user_id = _t54.member),
    'effective topic member gets a thread_state row');
SELECT ok(NOT EXISTS (SELECT 1 FROM thread_priority tp, _t54
    WHERE tp.thread_id = _t54.thread_id AND tp.user_id = _t54.optout),
    'opted-out user is NOT filed');

SELECT * FROM finish();
ROLLBACK;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd libs/db && pg_prove -d "$DATABASE_URL" tests/54-topic-peer-filing.sql`
Expected: FAIL — member has no `thread_priority` row (no trigger yet).

- [ ] **Step 3: Create the trigger** — `libs/db/schema/95-triggers/29-thread_topic_peers.sql`

```sql
-- When thread.topic_id is set/changed, file pending thread_priority +
-- thread_state rows for every EFFECTIVE topic member (minus the author and
-- opted-out users). The consumer Worker resolves each peer's priority via the
-- classifier. Mirrors file_thread_priority_for_group_members (23-thread_group_peers.sql).
CREATE OR REPLACE FUNCTION public.file_thread_priority_for_topic_members ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_author_user_id uuid;
BEGIN
    IF NEW.topic_id IS NULL THEN
        RETURN NEW;
    END IF;

    IF EXISTS (SELECT 1 FROM "public"."user" WHERE id = NEW.created_by) THEN
        v_author_user_id := NEW.created_by;
    ELSE
        v_author_user_id := NULL;
    END IF;

    INSERT INTO thread_priority (thread_id, user_id, priority_id, classify_at)
    SELECT NEW.id, peer_user_id, NULL::uuid, now()
    FROM (
        SELECT DISTINCT uc.user_id AS peer_user_id
        FROM topic_contact tc
        JOIN user_contact uc ON uc.contact_id = tc.contact_id
            AND uc.linked = TRUE AND uc.archived_at IS NULL
        WHERE tc.topic_id = NEW.topic_id
        UNION
        SELECT DISTINCT uc.user_id
        FROM topic_group tg
        JOIN group_member gm ON gm.group_id = tg.group_id
        JOIN user_contact uc ON uc.contact_id = gm.contact_id
            AND uc.linked = TRUE AND uc.archived_at IS NULL
        WHERE tg.topic_id = NEW.topic_id
    ) peers
    WHERE peer_user_id IS DISTINCT FROM v_author_user_id
      AND NOT EXISTS (
          SELECT 1 FROM topic_member_optout o
          WHERE o.topic_id = NEW.topic_id AND o.user_id = peers.peer_user_id
      )
    ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;

    INSERT INTO thread_state (user_id, thread_id)
    SELECT peer_user_id, NEW.id
    FROM (
        SELECT DISTINCT uc.user_id AS peer_user_id
        FROM topic_contact tc
        JOIN user_contact uc ON uc.contact_id = tc.contact_id
            AND uc.linked = TRUE AND uc.archived_at IS NULL
        WHERE tc.topic_id = NEW.topic_id
        UNION
        SELECT DISTINCT uc.user_id
        FROM topic_group tg
        JOIN group_member gm ON gm.group_id = tg.group_id
        JOIN user_contact uc ON uc.contact_id = gm.contact_id
            AND uc.linked = TRUE AND uc.archived_at IS NULL
        WHERE tg.topic_id = NEW.topic_id
    ) peers
    WHERE peer_user_id IS DISTINCT FROM v_author_user_id
      AND NOT EXISTS (
          SELECT 1 FROM topic_member_optout o
          WHERE o.topic_id = NEW.topic_id AND o.user_id = peers.peer_user_id
      )
    ON CONFLICT (user_id, thread_id) DO NOTHING;

    RETURN NEW;
END;
$$;

CREATE TRIGGER file_thread_priority_for_topic_members
    AFTER INSERT OR UPDATE OF topic_id
    ON public.thread
    FOR EACH ROW
    EXECUTE FUNCTION public.file_thread_priority_for_topic_members ();
```

- [ ] **Step 4: Apply migration**

Run: `cd libs/db && pnpm gen-migration -- file_topic_peers && pnpm apply-migrations`

- [ ] **Step 5: Run tests (this + Task 4) to verify they pass**

Run: `cd libs/db && pg_prove -d "$DATABASE_URL" tests/54-topic-peer-filing.sql tests/53-topic-thread-visibility.sql`
Expected: PASS (3/3 and 5/5).

- [ ] **Step 6: Verify sync + commit**

```bash
cd libs/db && pnpm diff-schema-migrations   # expect no changes
git add libs/db/schema/95-triggers/29-thread_topic_peers.sql \
        libs/db/tests/54-topic-peer-filing.sql libs/db/migrations/ libs/db/src/types.ts
git commit -m "feat(db): file thread_priority for topic members on topic_id set"
```

---

## Task 6: access-path helper + topic membership grant/revoke + transitive group→topic

**Files:**
- Create: `libs/db/schema/90-user-schema/09-user_has_thread_access.sql`
- Create: `libs/db/schema/95-triggers/30-topic_member_change.sql`
- Modify: `libs/db/schema/95-triggers/23-thread_group_peers.sql` (extend the existing group-member trigger to include topic threads and use the helper)
- Test: `libs/db/tests/55-topic-membership-propagation.sql`

- [ ] **Step 1: Write the failing test** — `libs/db/tests/55-topic-membership-propagation.sql`

```sql
-- Adding a contact/group to a topic grants access to all its threads;
-- removing revokes (when no other path remains). Leaving a member-group that
-- a topic includes revokes topic access transitively. Re-adding un-revokes.
BEGIN;
SET LOCAL search_path = public, extensions;
SELECT plan(6);

CREATE TEMP TABLE _t55 (alice uuid, alice_c uuid, group_id uuid, topic_id uuid, thread_id uuid);

DO $$
DECLARE
    v_author uuid := gen_random_uuid();
    v_alice uuid := gen_random_uuid();
    c_author uuid; c_alice uuid;
    v_group uuid := gen_random_uuid();
    v_topic uuid := gen_random_uuid();
    v_thread thread;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES
        (v_author,'a55@test.local'),(v_alice,'al55@test.local');
    c_author := public.upsert_user_contact(v_author,'a55@test.local','A',NULL);
    c_alice  := public.upsert_user_contact(v_alice,'al55@test.local','Al',NULL);

    INSERT INTO public."group" (id, name, type, created_by) VALUES (v_group,'G55','public',v_author);
    INSERT INTO public.topic (id, name, created_by) VALUES (v_topic,'T55',v_author);

    -- Thread exists in the topic BEFORE Alice joins.
    v_thread := "user".upsert_thread(v_author,
        jsonb_build_object('title','Backfill 55','topic_id', v_topic::text));

    INSERT INTO _t55 VALUES (v_alice, c_alice, v_group, v_topic, v_thread.id);
END $$;

-- Alice not yet a member → no row.
SELECT ok(NOT EXISTS (SELECT 1 FROM thread_priority tp, _t55
    WHERE tp.thread_id=_t55.thread_id AND tp.user_id=_t55.alice),
    'pre-join: Alice has no thread_priority row');

-- Add the group to the topic, then Alice to the group → transitive grant.
INSERT INTO public.topic_group (topic_id, group_id) SELECT topic_id, group_id FROM _t55;
INSERT INTO public.group_member (group_id, contact_id) SELECT group_id, alice_c FROM _t55;

SELECT ok(EXISTS (SELECT 1 FROM thread_priority tp, _t55
    WHERE tp.thread_id=_t55.thread_id AND tp.user_id=_t55.alice AND tp.revoked_at IS NULL),
    'post-join via group: Alice gains access to the topic back-catalog');

-- Leave the group → transitive revoke (group was her only path).
DELETE FROM public.group_member WHERE group_id=(SELECT group_id FROM _t55) AND contact_id=(SELECT alice_c FROM _t55);

SELECT ok(EXISTS (SELECT 1 FROM thread_priority tp, _t55
    WHERE tp.thread_id=_t55.thread_id AND tp.user_id=_t55.alice AND tp.revoked_at IS NOT NULL),
    'post-leave group: Alice access revoked (no other path)');

-- Re-add to group → un-revoke.
INSERT INTO public.group_member (group_id, contact_id) SELECT group_id, alice_c FROM _t55;
SELECT ok(EXISTS (SELECT 1 FROM thread_priority tp, _t55
    WHERE tp.thread_id=_t55.thread_id AND tp.user_id=_t55.alice AND tp.revoked_at IS NULL),
    'post-rejoin group: Alice access restored');

-- Add Alice directly as a topic_contact too (second path), then remove the
-- group path → access retained because the direct path remains.
INSERT INTO public.topic_contact (topic_id, contact_id) SELECT topic_id, alice_c FROM _t55;
DELETE FROM public.group_member WHERE group_id=(SELECT group_id FROM _t55) AND contact_id=(SELECT alice_c FROM _t55);
SELECT ok(EXISTS (SELECT 1 FROM thread_priority tp, _t55
    WHERE tp.thread_id=_t55.thread_id AND tp.user_id=_t55.alice AND tp.revoked_at IS NULL),
    'second path (direct topic_contact) keeps access after group leave');

-- Remove the direct topic_contact too → now revoked.
DELETE FROM public.topic_contact WHERE topic_id=(SELECT topic_id FROM _t55) AND contact_id=(SELECT alice_c FROM _t55);
SELECT ok(EXISTS (SELECT 1 FROM thread_priority tp, _t55
    WHERE tp.thread_id=_t55.thread_id AND tp.user_id=_t55.alice AND tp.revoked_at IS NOT NULL),
    'removing last path (direct topic_contact) revokes access');

SELECT * FROM finish();
ROLLBACK;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd libs/db && pg_prove -d "$DATABASE_URL" tests/55-topic-membership-propagation.sql`
Expected: FAIL — topic membership changes don't propagate yet.

- [ ] **Step 3: Create the access-path helper** — `libs/db/schema/90-user-schema/09-user_has_thread_access.sql`

```sql
-- Does the user still have ANY visibility path to this thread?
--   direct contact · group on the thread · the thread's topic.
-- The single source of truth for revoke decisions across all triggers, so
-- "lost my last path → revoke" is computed identically everywhere.
CREATE OR REPLACE FUNCTION "user".user_has_thread_access (p_user_id uuid, p_thread_id uuid)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    AS $$
    SELECT EXISTS (
        SELECT 1 FROM thread t
        WHERE t.id = p_thread_id
          AND (
              t.contacts && "user".user_contact_ids(p_user_id)
              OR t.groups && "user".user_group_ids(p_user_id)
              OR (t.topic_id IS NOT NULL AND t.topic_id = ANY("user".user_topic_ids(p_user_id)))
          )
    );
$$;
```

- [ ] **Step 4: Extend the group-member trigger** — replace `file_thread_priority_on_group_member_change` in `libs/db/schema/95-triggers/23-thread_group_peers.sql` so both branches consider topic threads (threads whose `topic_id` is in a topic that includes the changed group) and use the helper for the revoke check. Replace the function body (lines 80–194) with:

```sql
CREATE OR REPLACE FUNCTION public.file_thread_priority_on_group_member_change ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    r_thread RECORD;
    v_peer_user_id uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT uc.user_id INTO v_peer_user_id
        FROM public.user_contact uc
        WHERE uc.contact_id = NEW.contact_id AND uc.linked = TRUE AND uc.archived_at IS NULL
        LIMIT 1;
        IF v_peer_user_id IS NULL THEN RETURN NEW; END IF;

        WITH affected AS (
            -- threads that reference the group directly …
            SELECT t.id AS thread_id FROM public.thread t
            WHERE NEW.group_id = ANY(t.groups) AND t.archived_at IS NULL
            UNION
            -- … or whose topic includes the group.
            SELECT t.id FROM public.thread t
            JOIN public.topic_group tg ON tg.group_id = NEW.group_id AND tg.topic_id = t.topic_id
            WHERE t.archived_at IS NULL
              AND NOT EXISTS (SELECT 1 FROM public.topic_member_optout o
                              WHERE o.topic_id = t.topic_id AND o.user_id = v_peer_user_id)
        ),
        candidates AS (
            SELECT a.thread_id, public.classify_thread_for_user(v_peer_user_id, a.thread_id) AS pid
            FROM affected a
        )
        INSERT INTO thread_priority (thread_id, user_id, priority_id, classify_at)
        SELECT c.thread_id, v_peer_user_id, c.pid,
               CASE WHEN c.pid IS NOT NULL THEN NULL ELSE now() END
        FROM candidates c
        ON CONFLICT ON CONSTRAINT thread_priority_pkey DO UPDATE
        SET revoked_at = NULL
        WHERE thread_priority.revoked_at IS NOT NULL;

        INSERT INTO thread_state (user_id, thread_id)
        SELECT v_peer_user_id, a.thread_id
        FROM (
            SELECT t.id AS thread_id FROM public.thread t
            WHERE NEW.group_id = ANY(t.groups) AND t.archived_at IS NULL
            UNION
            SELECT t.id FROM public.thread t
            JOIN public.topic_group tg ON tg.group_id = NEW.group_id AND tg.topic_id = t.topic_id
            WHERE t.archived_at IS NULL
              AND NOT EXISTS (SELECT 1 FROM public.topic_member_optout o
                              WHERE o.topic_id = t.topic_id AND o.user_id = v_peer_user_id)
        ) a
        ON CONFLICT (user_id, thread_id) DO NOTHING;

        RETURN NEW;

    ELSIF TG_OP = 'DELETE' THEN
        SELECT uc.user_id INTO v_peer_user_id
        FROM public.user_contact uc
        WHERE uc.contact_id = OLD.contact_id AND uc.linked = TRUE AND uc.archived_at IS NULL
        LIMIT 1;
        IF v_peer_user_id IS NULL THEN RETURN OLD; END IF;

        FOR r_thread IN
            SELECT t.id AS thread_id FROM public.thread t
            WHERE OLD.group_id = ANY(t.groups) AND t.archived_at IS NULL
            UNION
            SELECT t.id FROM public.thread t
            JOIN public.topic_group tg ON tg.group_id = OLD.group_id AND tg.topic_id = t.topic_id
            WHERE t.archived_at IS NULL
        LOOP
            IF NOT "user".user_has_thread_access(v_peer_user_id, r_thread.thread_id) THEN
                UPDATE thread_priority SET revoked_at = now()
                WHERE thread_id = r_thread.thread_id AND user_id = v_peer_user_id AND revoked_at IS NULL;
                DELETE FROM thread_state
                WHERE thread_id = r_thread.thread_id AND user_id = v_peer_user_id;
            END IF;
        END LOOP;

        RETURN OLD;
    END IF;
END;
$$;
```

(The `CREATE TRIGGER file_thread_priority_on_group_member_change` at the bottom of the file is unchanged.)

- [ ] **Step 5: Create topic-membership-change triggers** — `libs/db/schema/95-triggers/30-topic_member_change.sql`

```sql
-- topic_contact / topic_group membership changes grant or revoke access to
-- every thread in the topic, mirroring file_thread_priority_on_group_member_change.
-- INSERT classifies inline so the back-catalog appears immediately; DELETE
-- revokes only when user.user_has_thread_access finds no remaining path.

-- Helper: grant a single user access to all of a topic's threads.
CREATE OR REPLACE FUNCTION public.grant_topic_threads_to_user (p_topic_id uuid, p_user_id uuid)
    RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    -- Respect opt-out: a user who left does not get re-added by a membership change.
    IF EXISTS (SELECT 1 FROM topic_member_optout o WHERE o.topic_id = p_topic_id AND o.user_id = p_user_id) THEN
        RETURN;
    END IF;

    WITH candidates AS (
        SELECT t.id AS thread_id, public.classify_thread_for_user(p_user_id, t.id) AS pid
        FROM public.thread t
        WHERE t.topic_id = p_topic_id AND t.archived_at IS NULL
    )
    INSERT INTO thread_priority (thread_id, user_id, priority_id, classify_at)
    SELECT c.thread_id, p_user_id, c.pid,
           CASE WHEN c.pid IS NOT NULL THEN NULL ELSE now() END
    FROM candidates c
    ON CONFLICT ON CONSTRAINT thread_priority_pkey DO UPDATE
    SET revoked_at = NULL
    WHERE thread_priority.revoked_at IS NOT NULL;

    INSERT INTO thread_state (user_id, thread_id)
    SELECT p_user_id, t.id
    FROM public.thread t
    WHERE t.topic_id = p_topic_id AND t.archived_at IS NULL
    ON CONFLICT (user_id, thread_id) DO NOTHING;
END;
$$;

-- Helper: revoke a single user from a topic's threads when no other path remains.
CREATE OR REPLACE FUNCTION public.revoke_topic_threads_from_user (p_topic_id uuid, p_user_id uuid)
    RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    r_thread RECORD;
BEGIN
    FOR r_thread IN
        SELECT t.id AS thread_id FROM public.thread t
        WHERE t.topic_id = p_topic_id AND t.archived_at IS NULL
    LOOP
        IF NOT "user".user_has_thread_access(p_user_id, r_thread.thread_id) THEN
            UPDATE thread_priority SET revoked_at = now()
            WHERE thread_id = r_thread.thread_id AND user_id = p_user_id AND revoked_at IS NULL;
            DELETE FROM thread_state
            WHERE thread_id = r_thread.thread_id AND user_id = p_user_id;
        END IF;
    END LOOP;
END;
$$;

-- topic_contact: one contact → one user.
CREATE OR REPLACE FUNCTION public.file_thread_priority_on_topic_contact_change ()
    RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_user_id uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT uc.user_id INTO v_user_id FROM user_contact uc
        WHERE uc.contact_id = NEW.contact_id AND uc.linked = TRUE AND uc.archived_at IS NULL LIMIT 1;
        IF v_user_id IS NOT NULL THEN PERFORM public.grant_topic_threads_to_user(NEW.topic_id, v_user_id); END IF;
        RETURN NEW;
    ELSE
        SELECT uc.user_id INTO v_user_id FROM user_contact uc
        WHERE uc.contact_id = OLD.contact_id AND uc.linked = TRUE AND uc.archived_at IS NULL LIMIT 1;
        IF v_user_id IS NOT NULL THEN PERFORM public.revoke_topic_threads_from_user(OLD.topic_id, v_user_id); END IF;
        RETURN OLD;
    END IF;
END;
$$;

CREATE TRIGGER file_thread_priority_on_topic_contact_change
    AFTER INSERT OR DELETE ON public.topic_contact
    FOR EACH ROW EXECUTE FUNCTION public.file_thread_priority_on_topic_contact_change ();

-- topic_group: one group → all its members' users.
CREATE OR REPLACE FUNCTION public.file_thread_priority_on_topic_group_change ()
    RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_user_id uuid;
    v_topic_id uuid;
    v_group_id uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN v_topic_id := NEW.topic_id; v_group_id := NEW.group_id;
    ELSE v_topic_id := OLD.topic_id; v_group_id := OLD.group_id; END IF;

    FOR v_user_id IN
        SELECT DISTINCT uc.user_id FROM group_member gm
        JOIN user_contact uc ON uc.contact_id = gm.contact_id
            AND uc.linked = TRUE AND uc.archived_at IS NULL
        WHERE gm.group_id = v_group_id
    LOOP
        IF TG_OP = 'INSERT' THEN PERFORM public.grant_topic_threads_to_user(v_topic_id, v_user_id);
        ELSE PERFORM public.revoke_topic_threads_from_user(v_topic_id, v_user_id); END IF;
    END LOOP;

    IF TG_OP = 'INSERT' THEN RETURN NEW; ELSE RETURN OLD; END IF;
END;
$$;

CREATE TRIGGER file_thread_priority_on_topic_group_change
    AFTER INSERT OR DELETE ON public.topic_group
    FOR EACH ROW EXECUTE FUNCTION public.file_thread_priority_on_topic_group_change ();
```

- [ ] **Step 6: Apply migration**

Run: `cd libs/db && pnpm gen-migration -- topic_membership_propagation && pnpm apply-migrations`

- [ ] **Step 7: Run tests to verify they pass**

Run: `cd libs/db && pg_prove -d "$DATABASE_URL" tests/55-topic-membership-propagation.sql tests/33-access-loss-group-removal.sql`
Expected: PASS (6/6 and 13/13 — the existing group-removal test must still pass after the trigger rewrite).

- [ ] **Step 8: Verify sync + commit**

```bash
cd libs/db && pnpm diff-schema-migrations   # expect no changes
git add libs/db/schema/90-user-schema/09-user_has_thread_access.sql \
        libs/db/schema/95-triggers/30-topic_member_change.sql \
        libs/db/schema/95-triggers/23-thread_group_peers.sql \
        libs/db/tests/55-topic-membership-propagation.sql libs/db/migrations/ libs/db/src/types.ts
git commit -m "feat(db): topic membership propagation + transitive group→topic + access-path helper"
```

---

## Task 7: `topic_member_optout` — leave / rejoin propagation

**Files:**
- Create: `libs/db/schema/95-triggers/31-topic_optout_change.sql`
- Test: `libs/db/tests/56-topic-optout.sql`

- [ ] **Step 1: Write the failing test** — `libs/db/tests/56-topic-optout.sql`

```sql
-- Leaving a topic (opt-out) revokes the stream but keeps the topic visible;
-- a future post does not re-add the opted-out user; rejoining restores access.
BEGIN;
SET LOCAL search_path = public, extensions;
SELECT plan(4);

CREATE TEMP TABLE _t56 (member uuid, member_c uuid, topic_id uuid, thread1 uuid);

DO $$
DECLARE
    v_author uuid := gen_random_uuid();
    v_member uuid := gen_random_uuid();
    c_author uuid; c_member uuid;
    v_topic uuid := gen_random_uuid();
    v_thread thread;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES
        (v_author,'a56@test.local'),(v_member,'m56@test.local');
    c_author := public.upsert_user_contact(v_author,'a56@test.local','A',NULL);
    c_member := public.upsert_user_contact(v_member,'m56@test.local','M',NULL);

    INSERT INTO public.topic (id, name, created_by) VALUES (v_topic,'T56',v_author);
    INSERT INTO public.topic_contact (topic_id, contact_id) VALUES (v_topic, c_member);

    v_thread := "user".upsert_thread(v_author,
        jsonb_build_object('title','Optout thread 1','topic_id', v_topic::text));

    INSERT INTO _t56 VALUES (v_member, c_member, v_topic, v_thread.id);
END $$;

-- Member has access pre-optout.
SELECT ok(EXISTS (SELECT 1 FROM thread_priority tp, _t56
    WHERE tp.thread_id=_t56.thread1 AND tp.user_id=_t56.member AND tp.revoked_at IS NULL),
    'pre-optout: member has access');

-- Leave the topic.
INSERT INTO public.topic_member_optout (topic_id, user_id) SELECT topic_id, member FROM _t56;

SELECT ok(EXISTS (SELECT 1 FROM thread_priority tp, _t56
    WHERE tp.thread_id=_t56.thread1 AND tp.user_id=_t56.member AND tp.revoked_at IS NOT NULL),
    'post-optout: existing thread access revoked');

-- A new post to the topic must NOT re-add the opted-out member.
DO $$
DECLARE v_author uuid; v_t thread;
BEGIN
    SELECT created_by INTO v_author FROM public.topic WHERE id = (SELECT topic_id FROM _t56);
    v_t := "user".upsert_thread(v_author,
        jsonb_build_object('title','Optout thread 2','topic_id',(SELECT topic_id FROM _t56)::text));
END $$;

SELECT ok(NOT EXISTS (
    SELECT 1 FROM thread_priority tp, _t56, public.thread th
    WHERE th.topic_id=_t56.topic_id AND th.title='Optout thread 2'
      AND tp.thread_id=th.id AND tp.user_id=_t56.member AND tp.revoked_at IS NULL),
    'post-optout: new topic post does not reach the opted-out member');

-- Rejoin (clear opt-out) → access restored to the back-catalog.
DELETE FROM public.topic_member_optout WHERE topic_id=(SELECT topic_id FROM _t56) AND user_id=(SELECT member FROM _t56);

SELECT ok(EXISTS (SELECT 1 FROM thread_priority tp, _t56
    WHERE tp.thread_id=_t56.thread1 AND tp.user_id=_t56.member AND tp.revoked_at IS NULL),
    'post-rejoin: access restored');

SELECT * FROM finish();
ROLLBACK;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd libs/db && pg_prove -d "$DATABASE_URL" tests/56-topic-optout.sql`
Expected: FAIL — opt-out does not revoke / rejoin does not restore (no trigger yet).

- [ ] **Step 3: Create the opt-out trigger** — `libs/db/schema/95-triggers/31-topic_optout_change.sql`

```sql
-- Leaving a topic (INSERT into topic_member_optout) revokes the user's access
-- to the topic's threads when no other path remains; rejoining (DELETE) grants
-- it back. Reuses the grant/revoke helpers from 30-topic_member_change.sql.
CREATE OR REPLACE FUNCTION public.file_thread_priority_on_topic_optout_change ()
    RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        PERFORM public.revoke_topic_threads_from_user(NEW.topic_id, NEW.user_id);
        RETURN NEW;
    ELSE
        PERFORM public.grant_topic_threads_to_user(OLD.topic_id, OLD.user_id);
        RETURN OLD;
    END IF;
END;
$$;

CREATE TRIGGER file_thread_priority_on_topic_optout_change
    AFTER INSERT OR DELETE ON public.topic_member_optout
    FOR EACH ROW EXECUTE FUNCTION public.file_thread_priority_on_topic_optout_change ();
```

- [ ] **Step 4: Apply migration**

Run: `cd libs/db && pnpm gen-migration -- topic_optout_propagation && pnpm apply-migrations`

- [ ] **Step 5: Run the full topic test suite to verify**

Run: `cd libs/db && pg_prove -d "$DATABASE_URL" tests/5*.sql tests/33-access-loss-group-removal.sql`
Expected: PASS across `50`–`56` and `33`.

- [ ] **Step 6: Verify sync + commit**

```bash
cd libs/db && pnpm diff-schema-migrations   # expect no changes
git add libs/db/schema/95-triggers/31-topic_optout_change.sql \
        libs/db/tests/56-topic-optout.sql libs/db/migrations/ libs/db/src/types.ts
git commit -m "feat(db): topic opt-out (leave/rejoin) propagation"
```

---

## Task 8: Full-suite regression + db:lint

**Files:** none (verification only)

- [ ] **Step 1: Run the entire pgTAP suite**

Run: `cd libs/db && pnpm gen-migration -- _noop_check; pnpm diff-schema-migrations`
Expected: `diff-schema-migrations` reports no changes (delete the throwaway `_noop_check` migration if `gen-migration` created an empty one). Then:

Run: `cd libs/db && pg_prove -d "$DATABASE_URL" tests/*.sql`
Expected: all test files PASS — especially the pre-existing visibility tests (`30`–`35`, `44`) which exercise `user.thread` and must survive the visibility-predicate change.

- [ ] **Step 2: Confirm committed types are current (CI parity)**

Run: `cd libs/db && pnpm --filter @plotday/db run lint`
Expected: passes (no "Type definitions are out of date").

- [ ] **Step 3: Final commit if anything changed**

```bash
git add -A libs/db
git commit -m "test(db): full pgTAP suite green for topic foundation" || echo "nothing to commit"
```

---

## Self-Review

**Spec coverage (Plan 1 scope only):**
- Topic entity + membership (contacts/groups/admins) → Tasks 1, 3. ✅
- `thread.topic_id` ≤1 + routing string → Task 2. ✅
- Effective membership composition − opt-outs → Task 3. ✅
- Thread visibility via topic path → Task 4. ✅
- `user.topic` read-model (opted-out still visible) → Task 4. ✅
- Membership propagation to all topic threads (join → back-catalog; leave → revoke) → Tasks 5, 6. ✅
- Transitive group→topic grant/revoke → Task 6. ✅
- Widened access-path predicate (single helper) → Task 6. ✅
- Per-user leave/rejoin overriding group-derived membership → Task 7. ✅
- Reuse of revoked-stub access-loss cleanup → Tasks 6, 7 (via `revoked_at` + existing `user.thread_redacted`). ✅
- **Deferred (later plans, noted):** group privacy enum (Plan 2); `/sync/topics`, `user.topic_redacted` + topic-entity access-loss, snapshot-expansion helper (Plan 3); client store (Plan 4); Plot Users/Plot Updates + onboarding migration (Plan 5).

**Placeholder scan:** none — every step has concrete SQL/commands.

**Type/name consistency:** `user.user_topic_ids`, `user.user_has_thread_access`, `grant_topic_threads_to_user`, `revoke_topic_threads_from_user`, `file_thread_priority_for_topic_members`, `file_thread_priority_on_topic_contact_change`, `file_thread_priority_on_topic_group_change`, `file_thread_priority_on_topic_optout_change` are used consistently across tasks. `thread.topic_id`, `topic.announce`, `topic.join_policy`, `topic_member_optout` names match across schema, views, and tests.

**Open risk flagged for executor:** Task 4's member-visibility assertion depends on Task 5's peer-filing trigger; run Task 5 before re-confirming Task 4 (noted inline). The `classify_thread_for_user` call inside grant helpers is the same inline-classify pattern the group trigger already uses — if a topic thread can't be classified (no matching priority), the row stays pending (`classify_at` set), which is correct.
